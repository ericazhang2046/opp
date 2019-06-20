source("opp.R")


load <- function(analysis_name = "vod") {

  # NOTE: test locations
  tbl <- tribble(
    ~state, ~city,
    "WA", "Seattle",
    "WA", "Statewide",
    "CT", "Hartford"
  )
  # tbl <- opp_available()

  if (analysis_name == "vod") {
    load_func <- load_vod_for
  } else if (analysis_name == "disparity") {
    load_func <- load_disparity_for
  } else if (analysis_name == "mj") {
    load_func <- load_mj_for
  }

  d <-
    opp_apply(
      function(state, city) {
        d <- load_func(state, city)
        # NOTE: opp_apply already uses state as key for each process/output
        city <- str_to_title(city)
        metadata <- list()
        metadata[[city]] <- list()
        metadata[[city]] <- d$metadata
        d$metadata <- metadata
        d
      },
      tbl
    ) %>% purrr::transpose()
  
  list(
    data = bind_rows(d$data),
    metadata = collapse_duplicate_keys(d$metadata)
  )
}


load_vod_for <- function(state, city) {
  load_base_for(state, city) %>%
  filter_to_locations_with_subgeography
  # TODO(danj/amyshoe): Do we want to add the dst and non-dst filters here?
  # (two separate functions, one filtering to complete years, on filtering 
  # to complete season-ranges)
}


load_disparity_for <- function(state, city) {
  load_base_for(state, city) %|%
  filter_to_locations_with_subgeography_by_year %|%
  filter_to_sufficient_search_info %|%
  filter_to_discretionary_searches %|%
  filter_to_sufficient_contraband_info %|%
  filter_to_locations_with_subgeography
}


load_mj_for <- function(state, city) {
  load_base_for(state, city) %|%
  filter_to_locations_with_data_before_and_after_legalization %|%
  filter_out_states_with_unreliable_search_data %|%
  filter_to_sufficient_search_info 
}


load_base_for <- function(state, city) {
  opp_load_clean_data(state, city) %>%
  # NOTE: raw columns are not used in the analyses
  select(-matches("raw_")) %>%
  mutate(state = state, city = city) %|%
  keep_only_highway_patrol_if_state %|%
  filter_to_vehicular_stops %|%
  filter_to_analysis_years %|%
  filter_to_analysis_races_by_year %|%
  add_subgeography %|%
  filter_out_anomalous_subgeographies
}


filter_to_vehicular_stops <- function(tbl, log) {
  log(list(type_proportion = count_pct(tbl, type)))
  tbl <- filter(tbl, type == "vehicular")
  tbl
}


filter_to_analysis_years <- function(tbl, log) {
  tbl <- filter(tbl, year(date) %in% 2011:2018)
  log(list(date_range = range(tbl$date)))
  threshold <- 500
  years_to_remove <- count(tbl, yr = year(date)) %>%
    filter(n < threshold) %>% 
    pull(yr)
  msg <- sprintf(
    "Year %d has fewer than %d stops recorded; removing year",
    years_to_remove, threshold
  )
  log(list(years_eliminated = msg))
  tbl <- tbl %>% filter(!(year(date) %in% years_to_remove))
  tbl
}

filter_to_analysis_races_by_year <- function(tbl, log) {
  if (!("subject_race") %in% colnames(tbl) | coverage_rate(tbl$subject_race) == 0) {
    log(list(reason_eliminated = "subject_race undefined"))
    return(tibble())
  }
  log(list(type_proportion = count_pct(tbl, subject_race)))
  threshold <- 0.65
  years_to_remove <- tbl %>% 
    mutate(yr = year(date)) %>% 
    group_by(yr) %>% 
    summarize(coverage_rate = coverage_rate(subject_race)) %>% 
    filter(coverage_rate < threshold) %>% 
    pull(yr)
  pct <- threshold * 100
  msg <- sprintf(
    "Removing year %d because subject_race non-null less than %g%% of the time", 
    years_to_remove, pct)
  log(list(years_eliminated = msg))
  tbl <- tbl %>% filter(!(year(date) %in% years_to_remove))
  
  tbl <- filter(tbl, subject_race %in% c("white", "black", "hispanic"))
  tbl
}


keep_only_highway_patrol_if_state <- function(tbl, log) {
  # NOTE: if it's a state and there are multiple departments listed,
  # filter to only the highway patrol stops
  if (tbl$city[[1]] == "Statewide" & "department_name" %in% colnames(tbl)) {
    filter(
      tbl,
      case_when(
        state == "NC" ~ department_name == "NC State Highway Patrol",
        state == "IL" ~ department_name == "ILLINOIS STATE POLICE",
        state == "CT" ~ department_name == "State Police",
        state == "MD" ~ department_name %in% c("Maryland State Police", "MSP"),
        state == "MS" ~ department_name == "Mississippi Highway Patrol",
        state == "MO" ~ department_name == "Missouri State Highway Patrol",
        state == "NE" ~ department_name == "Nebraska State Agency",
        # NOTE: it's a state, but none of those above, so keep it all
        TRUE ~ TRUE
      )
    )
  } else {
    tbl
  }
}


add_subgeography <- function(tbl, log) {

  subgeography_colnames <-
    if (tbl$city[[1]] == "Statewide") {
      quos_names(state_subgeographies)
    } else {
      quos_names(city_subgeographies)
    }

  subgeographies <- select_or_add_as_na(tbl, subgeography_colnames)
  subgeography <- subgeographies %>% select_if(funs(which.min(sum(is.na(.)))))
  subgeography_selected <- colnames(subgeography)[[1]]

  log(list(stats = 
    left_join(
      null_rates(subgeographies),
      n_distinct_values(subgeographies)
    ) %>%
    mutate(selected = feature == subgeography_selected)
  ))
  
  colnames(subgeography) <- "subgeography"
  bind_cols(tbl, subgeography)
}


filter_out_anomalous_subgeographies <- function(tbl, log) {
  filter(
    tbl,
    case_when(
      # NOTE: This is not a real district; it's mostly airport and HQ
      city == "Philadelphia" ~ subgeography != "77",
      city == "San Diego" ~ subgeography != "Unknown",
      city == "Nashville" ~ subgeography != "U",
      TRUE ~ TRUE
    )
  )
}


filter_to_locations_with_subgeography_by_year <- function(tbl, log) {
  threshold <- 0.6
  years_to_remove <- tbl %>% 
    mutate(yr = year(date)) %>% 
    group_by(yr) %>% 
    summarize(coverage_rate = coverage_rate(subgeography)) %>% 
    filter(coverage_rate < threshold) %>% 
    pull(yr)
  pct <- threshold * 100
  msg <- sprintf(
    "Removing year %d because subgeography non-null less than %g%% of the time", 
    years_to_remove, pct)
  log(list(years_eliminated = msg))
  tbl <- tbl %>% filter(!(year(date) %in% years_to_remove))
  tbl
}


filter_to_sufficient_search_info <- function(tbl, log) {
  if (!("search_conducted") %in% colnames(tbl)) {
    log(list(reason_eliminated = "search info not collected"))
    return(tibble())
  }
  log(list(search_proportion = count_pct(tbl, search_conducted)))
  threshold <- 0.5
  if (coverage_rate(tbl$search_conducted) < threshold) {
    pct <- threshold * 100
    msg <- sprintf("search_conducted non-null less than %g%% of the time", pct)
    log(list(reason_eliminated = msg))
    return(tibble())
  }
  tbl <- filter(tbl, !is.na(search_conducted))
  tbl
}


filter_to_discretionary_searches <- function(tbl, log) {
  if (!("search_basis") %in% colnames(tbl)) {
    log(list(missing_info = "search basis not given; keeping all searches"))
    return(tbl)
  }
  log(list(search_basis_proportion = tbl %>% 
             filter(search_conducted) %>% 
             count_pct(search_basis)
  ))
  # NOTE: If, among searches, we have search_basis info less than 50% of the 
  # time, we consider the search_basis column too unreliable to use, and 
  # simply use all searches.
  threshold <- 0.5
  if (tbl %>% 
      filter(search_conducted) %>% 
      pull(search_basis) %>% 
      coverage_rate() < threshold) {
    pct <- threshold * 100
    msg <- sprintf(
      "search_basis non-null less than %g%% of the time when search_conducted; keeping all searches", 
      pct)
    log(list(exception = msg))
    return(tbl)
  }
  # NOTE: Excludes "other" (i.e., arrest/warrant, probation/parole, inventory)
  tbl <- filter(tbl, is.na(search_basis) | search_basis %in% 
                  c("plain view", "consent", "probable cause", "k9"))
  tbl
}


filter_to_sufficient_contraband_info <- function(tbl, log) {
  if (!("contraband_found") %in% colnames(tbl)) {
    log(list(reason_eliminated = "contraband info not collected"))
    return(tibble())
  }
  log(list(contraband_proportion = 
             count_pct(tbl, search_conducted, contraband_found)))
  null_rate_threshold <- 0.5
  if (tbl %>% 
        filter(search_conducted) %>% 
        pull(contraband_found) %>% 
        coverage_rate() < null_rate_threshold) { 
    pct <- null_rate_threshold * 100
    msg <- sprintf(
      "contraband_found non-null less than %g%% of the time when search_conducted", 
      pct
    )
    log(list(reason_eliminated = msg))
    return(tibble())
  }
  hit_rate_threshold <- 0.02
  
  if (mean(filter(tbl, search_conducted)$contraband_found, na.rm = T) < hit_rate_threshold) {
    pct <- hit_rate_threshold * 100
    msg <- sprintf("hit rate is less than %g%%; suspiciously low", pct)
    log(list(reason_eliminated = msg))
    return(tibble())
  }
  tbl
}


filter_to_locations_with_data_before_and_after_legalization <- function(tbl, log) {
  date_range <- range(tbl$date, na.rm = TRUE)
  start_year <- year(date_range[1])
  end_year <- year(date_range[2])
  if (start_year < 2012 & end_year > 2012) {
    return(tbl)
  } else {
    msg <- "state does not have data before and after 2012"
    log(list(elimination_reason = msg))
    return(tibble())
  }
}


filter_out_states_with_unreliable_search_data <- function(tbl, log) {
  msg <- c(
    "IL removed because search recording policy changes year to year",
    "MD removed because before 2013 we are only given annual data",
    "MO removed because it's all annual data",
    "NE removed because it has unreliable quarterly dates, i.e. in 2012 all patrol stops are in Q1"
  )
  log(msg)
  filter(tbl, !(state %in% c("IL", "MD", "MO", "NE")))
}


filter_out_subeographies_with_insufficent_data <- function(tbl, log) {
  # TODO
}