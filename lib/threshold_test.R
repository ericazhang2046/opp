library(here)
source(here::here("lib", "opp.R"))

#' Threshold Test
#'
#' Infer and compare thresholds used for determining whether to execute
#' an action, i.e. thresholds used by officers to determine whether to search
#' someone based on race
#'
#' @param tbl tibble containing the following data
#' @param subgeography_col geographic subdivision to control for when inferring
#'        thresholds; (e.g., police district when testing cities, or county when
#'        testing states, etc.)
#' @param geography_col contains a population division of interest to use 
#'        hierarchically, i.e. if multiple cities are being test at the district
#'        level, geography_col = city
#' @param demographic_col contains a population division of interest, i.e. race,
#'        age group, sex, etc...
#' @param action_col identifies the risk population, i.e. those who were
#'        searched, frisked, summoned, etc...
#' @param outcome_col contains the results of action specified by
#'        \code{action_col}, i.e. if a search was conducted, an outcome
#'        might be whether contraband was found
#' @param n_iter maximum number of iterations
#' @param n_cores number of cores to use
#' 
#' 
#' @return list with \code{data}, \code{results}, and \code{metadata} keys
#'
#' @examples
#' threshold_test(tbl)
#' threshold_test(
#'   tbl,
#'   precinct,
#'   demographic_col = subject_race,
#'   action_col = search_conducted,
#'   outcome_col = contraband_found
#' )
#' NOTE: If using this hierarchical threshold test on just one location (e.g.,
#' one state or one city, `geography_col` will be populated with just one 
#' value, like the name of that city, or something)
threshold_test <- function(
  tbl,
  subgeography_col,
  geography_col = city,
  demographic_col = subject_race,
  action_col = search_conducted,
  outcome_col = contraband_found,
  majority_demographic = "white",
  n_iter = 5000,
  n_cores = min(5, parallel::detectCores() / 2),
  prior_scaling_factor = 1
) {
  
  subgeography_colq <- enquo(subgeography_col)
  geography_colq <- enquo(geography_col)
  demographic_colq <- enquo(demographic_col)
  action_colq <- enquo(action_col)
  outcome_colq <- enquo(outcome_col)

  metadata <- list()
  tbl <- opp_prepare_for_disparity(
    tbl,
    !!subgeography_colq,
    !!geography_colq,
    demographic_col=!!demographic_colq,
    action_col=!!action_colq,
    outcome_col=!!outcome_colq,
    metadata=metadata
  )
  data_summary <- summarize_for_stan(
    tbl,
    subgeography_col=!!subgeography_colq,
    geography_col=!!geography_colq,
    demographic_col=!!demographic_colq,
    action_col=!!action_colq,
    outcome_col=!!outcome_colq,
    metadata=metadata
  )
  stan_data <- format_data_summary_for_stan(
    data_summary,
    prior_scaling_factor
  )
  fit <- stan_threshold_test(stan_data, n_iter, n_cores)
  stan_warnings <- summary(warnings())
  fit_summary <- summary(fit)$summary
  rhat <- fit_summary[,'Rhat'] %>% max(na.rm = T)
  n_eff <- fit_summary[,'n_eff'] %>% min(na.rm = T)

  posteriors <- rstan::extract(fit)

  summary_stats <- collect_average_threshold_test_summary_stats(
    data_summary,
    posteriors,
    !!demographic_colq,
    majority_demographic
  )

  list(
    metadata = c(
      metadata,
      list(
        stan_warnings = stan_warnings,
        rhat = rhat,
        n_eff = n_eff,
        n_iters = n_iter,
        posteriors = posteriors
      )
    ),
    results = list(
      thresholds = add_thresholds(data_summary, posteriors),
      aggregate_thresholds = summary_stats
    )
  )
}


summarize_for_stan <- function(
  tbl,
  subgeography_col,
  geography_col = city,
  demographic_col = subject_race,
  action_col = search_conducted,
  outcome_col = contraband_found,
  metadata = list()
) {

  subgeography_colq <- enquo(subgeography_col)
  geography_colq <- enquo(geography_col)
  demographic_colq <- enquo(demographic_col)
  action_colq <- enquo(action_col)
  outcome_colq <- enquo(outcome_col)

  tbl %>% 
    group_by(!!demographic_colq, !!geography_colq, !!subgeography_colq) %>%
    summarize(
      n = n(),
      n_action = sum(!!action_colq, na.rm = TRUE),
      n_outcome = sum(!!outcome_colq, na.rm = TRUE)
    ) %>% 
    ungroup() %>% 
    unite(subgeography, !!subgeography_colq, !!geography_colq, remove = F) %>% 
    unite(geography_race, !!geography_colq, !!demographic_colq, remove = F) %>% 
    # NOTE: keep original column values to map stan output to values
    mutate(
      race = !!demographic_colq,
      geography = !!geography_colq,
      subgeography_raw = subgeography,
      geography_raw = !!geography_colq
    ) %>% 
    mutate_at(
      .vars = c("race", "subgeography", "geography", "geography_race"),
      .funs = ~as.integer(factor(.x))
    )
}


format_data_summary_for_stan <- function(data_summary, prior_scaling_factor) {
  list(
    n_groups = nrow(data_summary),
    n_races = n_distinct(pull(data_summary, race)),
    n_subgeographies = n_distinct(pull(data_summary, subgeography)),
    n_geographies = n_distinct(pull(data_summary, geography)),
    race = pull(data_summary, race),
    subgeography = pull(data_summary, subgeography),
    geography_race = pull(data_summary, geography_race),
    stop_count = pull(data_summary, n),
    search_count = pull(data_summary, n_action),
    hit_count = pull(data_summary, n_outcome),
    prior_scaling_factor = prior_scaling_factor
  )
}


collect_average_threshold_test_summary_stats <- function(
  thresholds,
  posteriors,
  demographic_col = subject_race,
  majority_demographic = "white"
) {
  demographic_colq <- enquo(demographic_col)
  # get weighted avg of thresholds by geography
  avg_thresh_geo <- accumulateRowMeans(
    t(signal_to_percent(
      posteriors$threshold,
      posteriors$phi,
      posteriors$delta
    )),
    pull(thresholds, geography_race),
    thresholds$n
  )
  geography_idx_helper <- thresholds %>% 
    group_by(geography_race, race) %>% 
    summarize(count = n(), n = sum(n))
  # get unweighted averages of thresholds across geographies
  avg_thresh <- accumulateRowMeans(
    avg_thresh_geo,
    pull(geography_idx_helper, race)
  )
  format_summary_stats(
    thresholds, 
    avg_thresh,
    !!demographic_colq,
    majority_demographic
  )
} 


# converts the threshold signal into a percent value (0, 1)
signal_to_percent <- function(x, phi, delta){
  phi * dnorm(x, delta, 1) / 
    (phi * dnorm(x, delta, 1) + (1 - phi) * dnorm(x, 0, 1))
}


accumulateRowMeans <- function(
  # Matrix operation to perfrom accumulated row means over some sub-category i
  # @pre: length(i) == nrow(M)
  # @pre: length(w) == nrow(M)
  # e.g., 
  ## if rows of @M represent race-district thresholds, and
  ## if @i gives integer representation of which race each row in @M correspond
  ## to, then @output will be a matrix with by-race thresholds averaged across
  ## districts averages are weighted according to @w
  ## (or, default is unweighted avg)
  # @post: ncol(output) == ncol(M)
  # @post: nrow(output) == n_distinct(i)
  M, # matrix to perform accumulated row means on
  i, # lists which sub-category value each row in M corresponds to
  w = rep(1, nrow(M)), # values used to create weightings for averaging
  i_max = max(i)
) {
  weighted_indexer <- t(sapply(
    1:i_max, 
    function(j) { (i == j) * na_replace(w / sum(w[i == j]), 0) }
  ))
  weighted_indexer %*% M
}


na_replace <- function(x, r) if_else(is.finite(x), x, r)


format_summary_stats <- function(
  data_summary,
  avg_thresh,
  demographic_col = subject_race,
  majority_demographic = "white"
) {
  demographic_colq <- enquo(demographic_col)
  majority_idx <-
    data_summary %>% 
      filter(!!demographic_colq == majority_demographic) %>% 
      pull(race) %>% 
      # extracts a single value
      unique() 
  
  avg_diffs <- 
    avg_thresh[-majority_idx,] -
    matrix(
      rep(avg_thresh[majority_idx,], nrow(avg_thresh) - 1),
      nrow = nrow(avg_thresh) - 1
    ) 
  
  tibble(
    # TODO(amyshoe): make this less dependent on previous operations;
    # demographic == as.integer(factor(demographic_col)), so to get the
    # original labels back, we need to re-factor demographic_col; i.e.
    # it may originally have contained levels 1, 3, 5, but had to be
    # re-factored to 1, 2, 3 for use in stan; this means that the original
    # column still has levels 1, 3, 5, while demographic has levels 1, 2, 3
    # so we need to re-factorize and select levels to get the names; this is
    # very fragile and likely to break if preceding code changes
    race = levels(factor(pull(data_summary, !!demographic_colq))),
    avg_threshold = pretty_percent(rowMeans(avg_thresh)),
    threshold_ci = format_confidence_interval(avg_thresh),
    threshold_diff = append(
      pretty_percent(rowMeans(avg_diffs)), 
      "", 
      after = majority_idx - 1
    ),
    diff_ci = append(
      format_confidence_interval(avg_diffs), 
      "", 
      after = majority_idx - 1
    )
  )
}


format_confidence_interval <- function(
  # matrix over which confidence intervals are taken
  M,
  # dimension for which we're calculating CIs (defaults to rows; 2 = columns)
  keep_dim = 1,
  lower = 0.025, 
  upper = 0.975
) {
  apply(
    matrixStats::rowQuantiles(M, probs = c(lower, upper)), 
    keep_dim,
    function(v) { 
      v <- pretty_percent(v)
      vs <- str_c(v, collapse = ', ')
      str_c('(', vs, ')')
    }
  )
}


stan_threshold_test <- function(
  data,
  n_iter = 10000,
  n_cores = min(5, parallel::detectCores() / 2)
) {
  # NOTE: defaults; may expose more of these in the future
  allow_adaptive_step_size <- T
  initialization_method <- "random"
  min_acceptable_divergence_rate <- 0.05
  n_iter_per_progress_update <- 50
  n_iter_warmup <- min(5000, round(n_iter / 2))
  n_markov_chains <- 5
  nuts_max_tree_depth <- 12
  path_to_stan_model <- here::here("stan", "threshold_test_hierarchical_identified.stan")
  
  rstan::sampling(
    stan_model(path_to_stan_model),
    data,
    chains = n_markov_chains,
    control = list(
      adapt_delta = 1 - min_acceptable_divergence_rate,
      adapt_engaged = allow_adaptive_step_size,
      max_treedepth = nuts_max_tree_depth
    ),
    cores = n_cores,
    init = initialization_method,
    iter = n_iter,
    refresh = n_iter_per_progress_update,
    warmup = n_iter_warmup
  )
}


add_thresholds <- function(
  data_summary,
  posteriors
) {
  data_summary %>%
    mutate(
      threshold = colMeans(signal_to_percent(
        posteriors$threshold, 
        posteriors$phi, 
        posteriors$delta
      )),
      geography_code = geography,
      geography = geography_raw,
      subgeography_code = subgeography,
      subgeography = subgeography_raw
    )
}
