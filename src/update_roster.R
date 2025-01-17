# pre2002
build_rosters_shieldapi <- function(season) {
  cli::cli_alert_info("Using Shield API to build rosters!")
  roster <- nflapi::nflapi_roster(season) |>
    nflapi::nflapi_roster_parse() |>
    dplyr::mutate(
      season = as.integer(season),
      player_jersey_number = as.integer(player_jersey_number),
      player_nfl_experience = as.integer(player_nfl_experience),
      player_weight = as.integer(player_weight),
      player_height = as.integer(player_height),
      player_college_names = as.character(player_college_names),
      player_headshot = gsub(
        "\\{formatInstructions\\}",
        "f_auto,q_auto",
        player_headshot
      ),
      player_birth_date = lubridate::ymd(player_birth_date)
    ) |>
    dplyr::select(
      season,
      team_abbr = team_abbreviation,
      position = player_position_group,
      depth_chart_position = player_position,
      jersey_number = player_jersey_number,
      status_short_description = player_status,
      display_name = player_display_name,
      first_name = player_first_name,
      last_name = player_last_name,
      height = player_height,
      weight = player_weight,
      gsis_id = player_gsis_id,
      years_exp = player_nfl_experience,
      headshot = player_headshot,
      birth_date = player_birth_date
    ) |>
    dplyr::na_if("") |>
    dplyr::mutate_if(is.character, stringr::str_trim) |>
    dplyr::filter(!(is.na(team_abbr) & is.na(gsis_id)),
                  first_name != "Duplicate")
  return(roster)
}

# 2002-2015: data exchange, mostly
build_rosters_weekly_dataexchange <- function(season) {
  cli::cli_alert_info("Using the NFL Data Exchange to obtain roster information!")
  cli::cli_alert_info("Scraping team and weeks for {season}...")
  r <- httr::GET(
    handle = httr::handle('https://www.nfl.info') ,
    path = glue::glue(
      '/nfldataexchange/dataexchange.asmx/getClubs?lseason={season}'
    ),
    httr::authenticate('media', 'media'),
    url = NULL
  )
  teams <- httr::content(r) |>
    xml2::xml_contents() |>
    xml2::as_list() |>
    unlist() |>
    stack() |>
    unstack() |>
    dplyr::filter(!(ClubCode %in% c('AFC', 'NFC', 'RIC', 'SAN', 'CRT', 'IRV')))

  weeks <-
    purrr::map_dfr(c("REG", "POST"),
                   ~ ngsscrapR::scrape_schedule(season, .x)) |>
    dplyr::group_by(week, game_type) |>
    dplyr::summarise(.groups = "drop")

  team_gmtype_pair <- teams |>
    dplyr::select(teamId = ClubCode, Season) |>
    dplyr::mutate(join = 1) |>
    dplyr::left_join(data.frame(seasonType = c("REG", "POST"),
                                join = c(1, 1)), by = c("join")) |>
    dplyr::select(-c(join))

  cli::cli_alert_info("Scraping rosters for {season}...")
  scrape_rosters <- function() {
    p <- progressr::progressor(along = 1:nrow(team_gmtype_pair))
    weekly_rosters <-
      purrr::pmap_dfr(
        list(
          team_gmtype_pair$Season,
          team_gmtype_pair$seasonType,
          team_gmtype_pair$teamId
        ),
        \(x, y, z) {
          r <- httr::GET(
            handle = httr::handle('https://www.nfl.info') ,
            path = glue::glue(
              '/nfldataexchange/dataexchange.asmx/getRoster?lSeason={x}&lSeasonType={y}&lWeek=0&lClub={z}'
            ),
            httr::authenticate('media', 'media'),
            url = NULL
          )

          if (httr::content(r) |>
              xml2::xml_contents() |>
              length() != 0) {
            roster <- httr::content(r) |>
              xml2::xml_contents() |>
              xml2::as_list() |>
              unlist() |>
              stack() |>
              unstack(values ~ ind) |>
              (\(x) lapply(x, `length<-`, max(lengths(x))))() |>
              data.frame()
          } else {
            roster <- data.frame()
          }
          p()
          return(roster)
        }
      )
  }

  progressr::with_progress({
    weekly_rosters <- scrape_rosters() |>
      dplyr::mutate(
        depth_chart_position = NA_character_,
        years_exp = season - as.integer(EntryYear),
        gsis_it_id = NA_integer_,
        display_name = FootballName,
        short_name = NA_character_,
        uniform_number = JerseyNumber,
        status = NA_character_,
        current_team_id = NA_character_,
        smart_id = NA_integer_,
        headshot = NA_character_,
        position_group = NA_character_,
        ngs_position = NA_character_,
        ngs_position_group = NA_character_
      ) |>
      dplyr::select(
        Season,
        game_type = SeasonType,
        Week,
        JerseyNumber,
        LastName,
        FootballName,
        FirstName,
        Position,
        EntryYear,
        RookieYear,
        Height,
        Weight,
        DraftClub,
        DraftNumber,
        CollegeConference,
        StatusDescriptionAbbr,
        StatusShortDescription,
        gsis_it_id,
        GsisID,
        esb_id = EliasID,
        display_name,
        short_name,
        uniform_number,
        status,
        team_abbr = CurrentClub,
        current_team_id,
        smart_id,
        headshot,
        position_group,
        ngs_position,
        ngs_position_group,
        depth_chart_position,
        years_exp
      ) |>
      tibble::as_tibble(.name_repair = janitor::make_clean_names) |>
      dplyr::group_by(game_type) |>
      dplyr::mutate(week = dplyr::dense_rank(week)) |> # fixing some weirdness where we skip a week
      dplyr::ungroup() |>
      dplyr::mutate(
        game_type = dplyr::case_when(
          game_type == "POST" & week == 1 ~ "WC",
          game_type == "POST" &
            week == 2 ~ "DIV",
          game_type == "POST" &
            week == 3 ~ "CON",
          game_type == "POST" &
            week == 4 ~ "SB",
          T ~ game_type
        ),
        week = dplyr::case_when(
          game_type %in% c("WC", "DIV", "CON", "SB") ~ week + max(week[game_type == "REG"]),
          T ~ week
        ),
        display_name = paste(display_name, last_name)
      )
  })
  return(weekly_rosters)
}

# 2016+: NGS API
build_rosters_weekly_ngsapi <- function(season) {
  cli::cli_alert_info("Using NGS API to obtain roster information!")
  cli::cli_alert_info("Scraping team and weeks for {season}...")
  teams <- ngsscrapR::scrape_teams(season) |>
    dplyr::filter(!is.na(division_id))
  weeks <-
    purrr::map_dfr(c("REG", "POST"),
                   ~ ngsscrapR::scrape_schedule(season, .x)) |>
    dplyr::group_by(week, game_type) |>
    dplyr::summarise(.groups = "drop")
  team_week_pair <- teams |>
    dplyr::select(team_id) |>
    dplyr::mutate(join = 1) |>
    dplyr::left_join(weeks |>
                       dplyr::mutate(join = 1), by = c("join")) |>
    dplyr::select(-c(join)) |>
    dplyr::rename(teamId = team_id,
                  seasonType = game_type) |>
    dplyr::mutate(
      season = !!season,
      seasonType = dplyr::case_when(seasonType != "REG" ~ "POST",
                                    T ~ seasonType)
    )
  cli::cli_alert_info("Scraping rosters for {season}...")
  scrape_rosters <- function() {
    p <- progressr::progressor(along = 1:nrow(team_week_pair))
    weekly_rosters <-
      purrr::pmap_dfr(
        list(
          team_week_pair$teamId,
          team_week_pair$season,
          team_week_pair$seasonType,
          team_week_pair$week
        ),
        \(w, x, y, z) {
          roster <- ngsscrapR::scrape_roster(w, x, y, z)
          p()
          return(roster)
        }
      )
  }

  progressr::with_progress({
    weekly_rosters <- scrape_rosters() |>
      dplyr::mutate(years_exp = as.integer(season) - as.integer(entry_year)) |>
      dplyr::rename(
        position = position_group,
        depth_chart_position = position,
        game_type = season_type
      ) |>
      dplyr::group_by(game_type) |>
      dplyr::mutate(week = dplyr::dense_rank(week)) |> # fixing some weirdness where we skip a week
      dplyr::ungroup() |>
      dplyr::mutate(
        game_type = dplyr::case_when(
          game_type == "POST" & week == 1 ~ "WC",
          game_type == "POST" &
            week == 2 ~ "DIV",
          game_type == "POST" &
            week == 3 ~ "CON",
          game_type == "POST" &
            week == 4 ~ "SB",
          T ~ game_type
        ),
        week = dplyr::case_when(
          game_type %in% c("WC", "DIV", "CON", "SB") ~ week + max(week[game_type == "REG"]),
          T ~ week
        ),
      )
    weekly_rosters[["birth_date"]] <-
      NULL # sometimes ngsscrapR::scrape_rosters() returns this, sometimes it doesn't
  })

  return(weekly_rosters)

}

convert_weekly_to_season_rosters <- function(weekly_rosters) {
  roster <- weekly_rosters |>
    dplyr::group_by(season, team_abbr, week) |>
    dplyr::mutate(group_id = dplyr::cur_group_id()) |>
    dplyr::ungroup() |>
    dplyr::group_by(season, team_abbr) |>
    dplyr::filter(group_id == max(group_id)) |>
    dplyr::ungroup() |>
    dplyr::mutate(season = as.integer(season),
                  week = as.integer(week))
  return(roster)
}

fill_ids <- function(roster) {
  ids <- nflreadr::load_ff_playerids() |>
    dplyr::select(
      gsis_id,
      espn_id,
      yahoo_id,
      rotowire_id,
      pff_id,
      pfr_id,
      fantasy_data_id,
      sleeper_id,
      sportradar_id
    )

  roster <- roster |>
    dplyr::left_join(ids, by = c("gsis_id"), na_matches = "never") |>
    dplyr::left_join(
      nflreadr::load_players() |>
        dplyr::select(gsis_id, college = college_name) |>
        dplyr::distinct(),
      by = c("gsis_id")
    )

  roster <- roster |>
    dplyr::mutate(headshot_url = gsub("\\{formatInstructions\\}", "f_auto,q_auto", headshot)) |>
    dplyr::select(
      season,
      team = team_abbr,
      position,
      depth_chart_position,
      jersey_number,
      status = status_short_description,
      full_name = display_name,
      first_name,
      last_name,
      birth_date,
      height,
      weight,
      college,
      gsis_id,
      espn_id,
      sportradar_id,
      yahoo_id,
      rotowire_id,
      pff_id,
      pfr_id,
      fantasy_data_id,
      sleeper_id,
      years_exp,
      headshot_url,
      dplyr::any_of(
        c(
          "ngs_position",
          "week",
          "game_type",
          "status_description_abbr",
          "status_short_description",
          "football_name",
          "esb_id",
          "gsis_it_id",
          "smart_id",
          "entry_year",
          "rookie_year",
          "draft_club",
          "draft_number"
        )
      )
    ) |>
    dplyr::mutate(
      team = dplyr::case_when(team == "LAR" ~ "LA",
                              team == "OAK" ~ "LV",
                              TRUE ~ team),
      height = stringr::str_remove_all(height, "\\\""),
      height = stringr::str_replace_all(height, "'", "-"),
      season = as.integer(season)
    ) |>
    dplyr::arrange(team, position)

  return(roster)
}

build_rosters <-
  function(season = nflreadr:::most_recent_season(roster = TRUE)) {
    if (season < 2002) {
      roster <- build_rosters_shieldapi(season) |>
        fill_ids()
    }

    if (season < 2016 & season >= 2002) {
      weekly_rosters <- build_rosters_weekly_dataexchange(season)
      roster <- convert_weekly_to_season_rosters(weekly_rosters)
      shield <- build_rosters_shieldapi(season)
      weekly_rosters <- weekly_rosters |>
        dplyr::select(-c(status, height, weight, headshot)) |>
        dplyr::left_join(
          shield |>
            dplyr::select(gsis_id, status = status_short_description, height, weight, headshot, birth_date) |>
            dplyr::arrange(gsis_id, status) |>
            dplyr::distinct(.keep_all = TRUE),
          by = c("gsis_id"),
          na_matches = "never"
        ) |>
        fill_ids()
      roster <- roster |>
        dplyr::select(-c(status, height, weight, headshot)) |>
        dplyr::left_join(
          shield |>
            dplyr::select(gsis_id, status = status_short_description, height, weight, headshot, birth_date) |>
            dplyr::arrange(gsis_id, status) |>
            dplyr::distinct(gsis_id, .keep_all = TRUE),
          by = c("gsis_id"),
          na_matches = "never"
        ) |>
        fill_ids()
    }

    if (season >= 2016) {
      weekly_rosters <- build_rosters_weekly_ngsapi(season)
      roster <- convert_weekly_to_season_rosters(weekly_rosters)
      shield <- build_rosters_shieldapi(season)
      weekly_rosters <- weekly_rosters |>
        dplyr::select(-c(height)) |>
        dplyr::left_join(
          shield |>
            dplyr::select(gsis_id, birth_date, height) |>
            dplyr::distinct(),
          by = c("gsis_id"),
          na_matches = "never"
        ) |>
        fill_ids()
      roster <- roster |>
        dplyr::select(-c(height)) |>
        dplyr::left_join(
          shield |>
            dplyr::select(gsis_id, birth_date, height) |>
            dplyr::distinct(),
          by = c("gsis_id"),
          na_matches = "never"
        ) |>
        fill_ids()
    }

    if (season >= 2002) {
      cli::cli_alert_info("Save weekly rosters...")
      nflversedata::nflverse_save(
        data_frame = weekly_rosters,
        file_name =  glue::glue("roster_weekly_{season}"),
        nflverse_type = "weekly roster data",
        release_tag = "weekly_rosters"
      )
    }

    cli::cli_alert_info("Save season rosters...")
    nflversedata::nflverse_save(
      data_frame = roster,
      file_name =  glue::glue("roster_{season}"),
      nflverse_type = "roster data",
      release_tag = "rosters"
    )

    cli::cli_alert_info("DONE!")

    return(invisible(NULL))
  }

## build ALL rosters
# purrr::walk(1920:2022, build_rosters)

## build most recent roster
build_rosters()
