# Aim: demonstrate disaggregating polygons for #24

library(tidyverse)

if (!exists("site_name")) {
  site_name = "cricklewood"
}
if (!exists("sites")) {
  sites = sf::read_sf("data-small/all-sites.geojson")
}

j = sites$site_name == site_name
site = sites[j,]
path = file.path("data-small", site_name)
# set seed for reproducibility
set.seed(2021)
# see build.R

# Input parameters and data -----------------------------------------------
times = list(commute = list(hr = 8.5, sd = 0.3),
             town = list(hr = 11, sd = 2))
site_area = sf::read_sf(file.path(path, "site.geojson"))
desire_lines = sf::read_sf(file.path(path, "desire-lines-few.geojson"))
study_area = sf::read_sf(file.path(path, "small-study-area.geojson"))
# buildings = osmextract::oe_get(study_area, layer = "multipolygons")
osm_polygons = osmextract::oe_get(sf::st_centroid(study_area), layer = "multipolygons")

# get procedurally generated houses
# https://github.com/cyipt/actdev/issues/81
procgen_url = paste0(
  "http://abstreet.s3-website.us-east-2.amazonaws.com/dev/data/input/gb/",
  gsub(
    pattern = "-",
    replacement = "_",
    x = site_name
  ),
  "/procgen_houses.json.gz"
)
procgen_path = file.path(path, "procgen_houses.json")
procgen_path_gz = file.path(path, "procgen_houses.json.gz")

procgen_get = httr::GET(url = procgen_url,
                        httr::write_disk(procgen_path_gz, overwrite = TRUE))
procgen_exists = httr::status_code(procgen_get) != 404

# # # sanity check scenario data
# class(desire_lines)
# sum(desire_lines$trimode_base)
# sum(desire_lines$walk_base, desire_lines$cycle_base, desire_lines$drive_base)
# sum(desire_lines$walk_godutch, desire_lines$cycle_godutch, desire_lines$drive_godutch)

# table(buildings_in_zones$building)
building_types = c(
  "office",
  "industrial",
  "commercial",
  "retail",
  "warehouse",
  "civic",
  "public",
  "school",
  "college",
  "university",
  "hospital",
  "train_station",
  "pub",
  "sports_centre"
)
summary(factor(osm_polygons$building))

# show building = NA
# osm_polygons %>%
#   filter(is.na(building)) %>%
#   sample_n(size = 100) %>% mapview::mapview()

osm_buildings = osm_polygons %>%
  filter(!str_detect(string = building, "resi|house|semi|terrace|detached|apartments"))
# filter(building %in% building_types)
summary(factor(osm_buildings$building))

pct_zone = pct::pct_regions[site_area %>% sf::st_centroid(),]
zones = pct::get_pct_zones(pct_zone$region_name, geography = "msoa")
zones_of_interest = zones[zones$geo_code %in% c(desire_lines$geo_code1, desire_lines$geo_code2),]

# add town zone, see #74
zone_town = zones %>%
  sf::st_drop_geometry() %>%
  slice(1) %>%
  mutate_all(function(x)
    NA) %>%
  mutate(geo_code = tail(desire_lines$geo_code2, 1))
zone_town_geometry = lwgeom::st_endpoint(tail(desire_lines, 1)) %>%
  stplanr::geo_buffer(dist = 500)
zone_town_sf = sf::st_sf(zone_town, geometry = zone_town_geometry)
zones_of_interest = rbind(zones_of_interest, zone_town_sf)

error = FALSE
tryCatch({
  buildings_in_zones = osm_buildings[zones_of_interest, , op = sf::st_within]
}
, error = function(e) {
  error <<- TRUE
})
if (error) {
  buildings_in_zones = osm_buildings[zones_of_interest,]
}

if (procgen_exists) {
  system(paste0("gunzip ", procgen_path_gz))
  procgen_houses = sf::read_sf(procgen_path)
  file.remove(procgen_path)
}

#mapview::mapview(zones_of_interest) +
  mapview::mapview(buildings_in_zones)

buildings_in_zones = buildings_in_zones %>%
  select(osm_way_id, building)

n_buildings_per_zone = aggregate(buildings_in_zones, zones_of_interest, FUN = "length")
summary(n_buildings_per_zone$osm_way_id)
mbz = 10
zones_lacking_buildings = n_buildings_per_zone$osm_way_id < mbz
zones_lacking_buildings[is.na(zones_lacking_buildings)] = TRUE
if (any(zones_lacking_buildings)) {
  sz = rep(5, length(zones_lacking_buildings)) # n buildings per zone - arbitrary
  new_buildings = sf::st_sample(zones_of_interest[zones_lacking_buildings,], size = sz)
  new_buildings = sf::st_sf(
    data.frame(osm_way_id = rep(NA, length(new_buildings)), building = NA),
    geometry = stplanr::geo_buffer(new_buildings, dist = 20, nQuadSegs = 1)
  )
  new_buildings$building = "commercial" # todo: diversify - hardcoded
  buildings_in_zones = rbind(buildings_in_zones, new_buildings)
}

osm_polygons_in_site = osm_polygons[site_area, , op = sf::st_within]
houses = osm_polygons_in_site %>%
  filter(!is.na(building)) %>%
  # filter(building == "residential") %>% # todo: all non-destination buildings?
  select(osm_way_id, building)
# subset to those in the site
#mapview::mapview(site) + mapview::mapview(houses)

if (procgen_exists) {
  # quick fix for https://github.com/cyipt/actdev/issues/82
  # todo: update when new procedurally generated houses are available
  # site_area = stplanr::geo_buffer(site_area, dist = 250) # expand boundary for #82
  procgen_site = procgen_houses[site_area, , op = sf::st_within]
  procgen_osm = sf::st_sf(data.frame(
    osm_way_id = rep(NA, nrow(procgen_site)),
    building = rep(NA, nrow(procgen_site))
  ),
  geometry = procgen_site$geometry)
  houses = rbind(houses, procgen_osm)
}
# mapview::mapview(procgen_houses) +
#   mapview::mapview(site)

# Save the buildings and 'key destinations' datasets ----------------------
# mapview::mapview(houses) + mapview::mapview(site) # looks good, but includes houses outside the site!
houses_in_site = houses[site,]
n_houses = nrow(houses_in_site)
n_dwellings_site = site$dwellings_when_complete

if (n_houses < 5) {
  n_houses_to_generate = n_dwellings_site - n_houses
  new_house_centroids = sf::st_sample(site_area, size = n_houses_to_generate)
  new_house_polys = stplanr::geo_buffer(new_house_centroids, dist = 8, nQuadSegs = 1)
  plot(new_house_polys)
  new_houses = sf::st_sf(data.frame(
    osm_way_id = rep(NA, n_houses_to_generate),
    building = "synthetic"
  ),
  geometry = new_house_polys)
  houses = rbind(houses_in_site, new_houses)
} else {
  houses = houses_in_site
}

mapview::mapview(houses) + mapview::mapview(site)

if (!new_site) {
  dsn = file.path(path, "site_buildings.geojson")
  file.remove(dsn)
  sf::write_sf(houses, dsn)
}


trip_attractors = buildings_in_zones %>% filter(building %in% building_types)
#mapview::mapview(trip_attractors) # looks good!

if (!new_site) {
  dsn = file.path(path, "trip_attractors.geojson")
  file.remove(dsn)
  sf::write_sf(trip_attractors, dsn)
}


# # save summary info (todo: add more columns) ------------------------------
nrow(buildings_in_zones)
# sites_df = sites %>% sf::st_drop_geometry()
# sites_df$n_origin_buildings = NA
# sites_df$n_destination_buildings = NA
sites_df = readr::read_csv("data-small/sites_df_abstr.csv")
#error in merging rows for a new site
if (new_site) {
  newdf <- data.frame(
    site_name = site_name,
    dwellings_when_complete = n_dwellings_site,
    n_origin_buildings = nrow(houses),
    n_destination_buildings = nrow(buildings_in_zones)
  )
  
  sites_df = rbind(newdf, sites_df) %>% arrange(site_name)
  
  readr::write_csv(sites_df, "data-small/sites_df_abstr.csv")
}

# todo: allow setting the population column
names(desire_lines)
desire_lines$all_base = desire_lines$trimode_base
# desire_lines$departure = NA
# for(p in unique(desire_lines$purpose)) {
#   sel_p = desire_lines$purpose == p
#   tms = abstr::ab_time_normal(hr = times[[p]]$hr, sd = times[[p]]$sd, n = sum(sel_p))
#   desire_lines$departure[sel_p] = tms
# }

sel_zones_in_dests = desire_lines$geo_code2 %in% zones_of_interest[[1]]
if (!all(sel_zones_in_dests)) {
  dests_without_zones = which(!sel_zones_in_dests)
  warning("Desire lines without matching dest zone: ",
          dests_without_zones)
  desire_lines = desire_lines[sel_zones_in_dests,]
}
# work-around when town ID is missing
if (!"town" %in% desire_lines$purpose) {
  desire_lines$purpose[1] = "town"
}

# todo: generalise this code with some kind of loop
names(desire_lines) = gsub(pattern = "godutch",
                           replacement = "go_active",
                           names(desire_lines))
desire_lines = desire_lines %>% select(-matches("pc|pd"))
abs((
  sum(desire_lines$trimode_base) - sum(
    desire_lines$walk_base + desire_lines$cycle_base + desire_lines$drive_base
  )
) / sum(desire_lines$trimode_base)) * 100
abs((
  sum(desire_lines$trimode_base) - sum(
    desire_lines$walk_go_active + desire_lines$cycle_go_active + desire_lines$drive_go_active
  )
) / sum(desire_lines$trimode_base)) * 100
# % error should be less than ~1%

# # Check inputs for A/B Street scenarios
# mapview::mapview(houses) + mapview::mapview(buildings_in_zones) +
#   mapview::mapview(desire_lines) + mapview::mapview(zones_of_interest)

od = desire_lines %>% rename(Walk = walk_base, Bike = cycle_base, Drive = drive_base)

abc = abstr::ab_scenario(
  od = od %>% filter(purpose == "commute" &
                       all_base > 0),
  zones = site_area,
  zones_d = zones_of_interest,
  origin_buildings = houses,
  destination_buildings = buildings_in_zones,
  scenario = "base",
  output = "sf"
)

# to debug run: file.edit("~/cyipt/abstr/R/ab_scenario.R")

abc$departure = abstr::ab_time_normal(hr = times$commute$hr,
                                      sd = times$commute$sd,
                                      n = nrow(abc))
abt = abstr::ab_scenario(
  od = od %>% filter(purpose == "town" &
                       all_base > 0),
  zones = site_area,
  zones_d = zones_of_interest,
  origin_buildings = houses,
  destination_buildings = buildings_in_zones,
  scenario = "base",
  output = "sf"
)
table(abt$mode)

abt$departure = abstr::ab_time_normal(hr = times$town$hr,
                                      sd = times$town$sd,
                                      n = nrow(abt))
abb = rbind(abc, abt)
rows_equal = nrow(abb) == sum(desire_lines$trimode_base)
if (!rows_equal)
  stop("Number of trips in scenario different from baseline")
abbl = abstr::ab_json(abb, scenario_name = "base")

od_active = desire_lines %>% rename(Walk = walk_go_active, Bike = cycle_go_active, Drive = drive_go_active)

abcd = abstr::ab_scenario(
  od = od_active %>% filter(purpose == "commute" &
                       all_base > 0),
  zones = site_area,
  zones_d = zones_of_interest,
  origin_buildings = houses,
  destination_buildings = buildings_in_zones,
  scenario = "go_active",
  output = "sf"
)

mapview::mapview(abcd)

abcd$departure = abstr::ab_time_normal(hr = times$commute$hr,
                                       sd = times$commute$sd,
                                       n = nrow(abc))
abtd = abstr::ab_scenario(
  od = od_active %>% filter(purpose == "town"),
  zones = site_area,
  zones_d = zones_of_interest,
  origin_buildings = houses,
  destination_buildings = buildings_in_zones,
  scenario = "go_active",
  output = "sf"
)
nrow(abtd) == nrow(abt)
table(abtd$mode_go_active)
abtd$departure = abstr::ab_time_normal(hr = times$town$hr,
                                       sd = times$town$sd,
                                       n = nrow(abtd))
abbd = rbind(abcd, abtd)
rows_equal = nrow(abbd) == sum(desire_lines$trimode_base)
if (!rows_equal)
  stop("Number of trips in scenario different from baseline")
hist(abbd$departure, breaks = seq(0, 60 * 60 * 24, 60 * 15))
abbld = abstr::ab_json(abbd, scenario_name = "go_active")

table(abb$mode_base)
table(abbd$mode_go_active)

abstr::ab_save(abbl, file.path(path, "scenario_base.json"))
abstr::ab_save(abbld, file.path(path, "scenario_go_active.json"))


# why are we removing these // are they a duplicate of something? ----------------------
#file.remove(file.path(path, "scenario-base.json"))
#file.remove(file.path(path, "scenario-godutch.json"))

if (!exists("build_background_traffic")) {
  build_background_traffic = FALSE
}

if (build_background_traffic) {
  # add code to generate background traffic
  # simple visualisation of input data is a starter for 10
  if (!exists("od")) {
    od = pct::get_od()
    # for showing flows that start and end outside region
    # zones_national = pct::get_pct(geography = "msoa", layer = "z", national = TRUE)
    desire_lines_traffic = od::od_to_sf(x = od, z = zones_of_interest)
    nrow(desire_lines_traffic)
    # 3 times more driving in traffic in poundbury = good starting point
    sum(desire_lines_traffic$car_driver) / sum(desire_lines$drive_base)
    mapview::mapview(desire_lines_traffic) + mapview::mapview(zones_of_interest)
    
    houses_traffic = osm_polygons %>%
      filter(!is.na(building))
    
    class(desire_lines_traffic)
    names(desire_lines_traffic)[3:14] = paste0(names(desire_lines_traffic), "_traffic")[3:14]
    
    ab_background = abstr::ab_scenario(
      houses_traffic,
      buildings = buildings_in_zones,
      desire_lines = desire_lines,
      # desire_lines = desire_lines_traffic,
      zones = zones_of_interest,
      # scenario = "traffic",
      scenario = "base",
      output_format = "sf"
    )
    mapview::mapview(ab_background)
    names(ab_background)[1] = "mode_traffic"
    table(ab_background[[1]])
    sum(desire_lines_traffic$car_driver)
    ab_background_list = abstr::ab_json(ab_background)
    abstr::ab_save(ab_background_list,
                   "data-small/poundbury/scenario_background_traffic.json")
    readLines("data-small/poundbury/scenario_background_traffic.json")[1:30]
  }
}


# test in bash
# cd ~/other-repos/abstreet
# cargo run --release --bin import_traffic -- --map=data/system/gb/great_kneighton/maps/center.bin --input=/home/robin/cyipt/actdev/data-small/great-kneighton/scenario_go_active.json --skip_problems
# cargo run --release --bin game -- --dev data/system/gb/great_kneighton/maps/center.bin

# message(readLines(file.path(path, "scenario_go_active.json"), 2))

# idea: implement mode shift scenario on the disaggregate lines

# file.edit(file.path(path, "scenario.json"))

# # debugging / sanity checks:
# abstr_base_sf = abstr::ab_scenario(
#   houses,
#   buildings = buildings_in_zones,
#   desire_lines = desire_lines,
#   zones = zones_of_interest,
#   scenario = "base",
#   output_format = "sf"
# )
#
# abstr_go_active_sf = abstr::ab_scenario(
#   houses,
#   buildings = buildings_in_zones,
#   desire_lines = desire_lines,
#   zones = zones_of_interest,
#   scenario = "go_active",
#   output_format = "sf"
# )
#
# # scenarios look good!
# table(abstr_base_sf$mode_base)
# table(abstr_go_active_sf$mode_go_active)
#
# mapview::mapview(abstr_go_active_sf %>% sample_n(20)) +
#   mapview::mapview(houses)
