source("common.R")


# VALIDATION: [YELLOW] Data prior to 2009 looks like it could be incomplete,
# and 2017 only has part of the year. The Madison PD's Annual Report doesn't
# seem to contain traffic figures, but it does contain calls for service, which
# are around 200k each year. Given there are around 30k warnings and citations
# each year, this seems reasonable.
load_raw <- function(raw_data_dir, n_max) {
  # NOTE: "IBM" is the officers department ID
  cit <- load_single_file(
    raw_data_dir,
    "mpd_traffic_stop_request_citations.csv",
    n_max
  )
  warn <- load_single_file(
    raw_data_dir,
    "mpd_traffic_stop_request_warnings.csv",
    n_max
  )
  bundle_raw(
    bind_rows(cit$data, warn$data),
    c(cit$cloading_problems, warn$loading_problems)
  )
}


clean <- function(d, helpers) {

  # TODO(phoebe): can we get reason_for_stop/search/contraband data?
  # https://app.asana.com/0/456927885748233/595493946182539
  d$data %>%
  merge_rows(
    Date,
    Time,
    onStreet,
    onStreetName,
    OfficerName,
    Race,
    Sex,
    Make,
    Model,
    Year,
    State,
    Limit,
    OverLimit
  ) %>%
  rename(
    violation = `Statute Description`,
    vehicle_make = Make,
    vehicle_model = Model,
    vehicle_year = Year,
    vehicle_color = Color,
    vehicle_registration_state = State,
    posted_speed = Limit
  ) %>%
  separate_cols(
    OfficerName = c("officer_last_name", "officer_first_name")
  ) %>%
  mutate(
    # NOTE: Statute Descriptions are almost all vehicular, there are a few
    # pedestrian related Statute Descriptions, but it's unclear whether
    # the pedestrian or vehicle is failing to yield, but this represents a
    # quarter of a percent maximum
    type = "vehicular",
    speed = as.integer(posted_speed) + as.integer(OverLimit),
    date = parse_date(Date, "%Y/%m/%d"),
    time = parse_time(Time, "%H:%M:%S"),
    location = coalesce(onStreet, onStreetName),
    warning_issued = is.na(`Ticket #`),
    citation_issued = !is.na(`Ticket #`),
    # TODO(phoebe): can we get arrests?
    # https://app.asana.com/0/456927885748233/595493946182543
    outcome = first_of(
      citation = citation_issued,
      warning = warning_issued
    ),
    subject_race = tr_race[Race],
    subject_sex = tr_sex[Sex]
  ) %>%
  helpers$add_lat_lng(
  ) %>%
  helpers$add_shapefiles_data(
  ) %>%
  # NOTE: shapefiles don't appear to include district 2 and accompanying
  # sectors
  rename(
    sector = Sector,
    district = District,
    raw_race = Race
  ) %>%
  standardize(d$metadata)
}
