# ==============================================================================
# BTC REALIZED-VOLATILITY HORSE RACE — AESTHETIC VISUALIZATION SUITE
# ==============================================================================
#
# Creates a publication-quality / LinkedIn-quality visual pack from the output
# of btc_binance_realized_vol_horserace.R.
#
# EXPECTED INPUT FILES:
#   metrics.csv
#   forecasts.csv
#   bootstrap_tests.csv
#   dm_tests.csv
#   daily_realized_measures.csv
#   heavy_parameters.csv
#
# VISUAL SYSTEM:
#   Realized-GARCH = blue
#   HARQ           = blue-green
#   HEAVY          = vermillion
#   HAR-RV         = grey
#   GARCH          = charcoal
#
#   Statistical improvement = blue
#   Statistical deterioration = orange
#   Inconclusive = grey
#
# The palette is designed to be color-blind safer and to distinguish
# model identity from statistical direction.
#
# DEFAULT INPUT FOLDER:
#   results/btc_rv_horserace
#
# OUTPUT:
#   results/btc_rv_horserace/viz/
#
# FIGURES:
#   00_research_cover.png
#   01_qlike_leaderboard.png
#   02_relative_qlike_heatmap.png
#   03_cumulative_qlike_vs_har.png
#   04_realgarch_vs_harq.png
#   05_forecast_vs_realized.png
#   06_bootstrap_forest.png
#   07_regime_performance.png
#   08_heavy_parameter_evolution.png
#   09_research_dashboard.png
#
# ==============================================================================


# ==============================================================================
# 0. CONFIG
# ==============================================================================

DATA_DIR <- "results/btc_rv_horserace"
ZIP_FILE <- "btc_rv_horserace.zip"

OUT_DIR <- file.path(DATA_DIR, "viz")

# Restrict forecast plots to the models that communicate the story best.
FOCUS_MODELS <- c(
  "REALGARCH",
  "HARQ",
  "HEAVY_RM",
  "HAR_RV",
  "GARCH_11"
)

# Rolling smoother for the noisy forecast-vs-realized chart.
ROLLING_DAYS <- 14L

# PNG settings.
FIG_WIDTH <- 13
FIG_HEIGHT <- 7.5
FIG_DPI <- 300

# A clean editorial-finance palette.
COLORS <- c(
  "REALGARCH" = "#0072B2",  # strong blue
  "HARQ" = "#009E73",       # blue-green
  "HARQ_F" = "#56B4E9",     # light blue
  "HEAVY_RM" = "#D55E00",   # vermillion
  "HAR_J" = "#CC79A7",      # muted purple
  "HAR_RV" = "#8A8A8A",     # neutral benchmark grey
  "GARCH_11" = "#222222"    # charcoal benchmark
)

INK <- "#182026"
MUTED <- "#6B7280"
GRID <- "#DDD9D0"
PAPER <- "#F8F7F3"
WHITE <- "#FFFFFF"

# Statistical direction palette:
# blue = evidence model A is better
# orange = evidence model A is worse
# grey = inconclusive
POS <- "#0072B2"
NEG <- "#D55E00"
NEUTRAL <- "#9A948A"
ACCENT <- "#0072B2"

set.seed(12345)


# ==============================================================================
# 1. PACKAGES
# ==============================================================================

required_pkgs <- c(
  "ggplot2",
  "dplyr",
  "tidyr",
  "readr",
  "scales",
  "forcats",
  "patchwork",
  "zoo"
)

install_if_missing <- function(pkgs) {
  missing <- pkgs[
    !vapply(
      pkgs,
      requireNamespace,
      logical(1),
      quietly = TRUE
    )
  ]

  if (length(missing) > 0L) {
    message(
      "Installing missing packages: ",
      paste(missing, collapse = ", ")
    )

    install.packages(
      missing,
      repos = "https://cloud.r-project.org"
    )
  }

  still_missing <- pkgs[
    !vapply(
      pkgs,
      requireNamespace,
      logical(1),
      quietly = TRUE
    )
  ]

  if (length(still_missing) > 0L) {
    stop(
      "Could not install/load: ",
      paste(still_missing, collapse = ", ")
    )
  }
}

install_if_missing(required_pkgs)


# ==============================================================================
# 2. LOCATE / LOAD DATA
# ==============================================================================

required_files <- c(
  "metrics.csv",
  "forecasts.csv",
  "bootstrap_tests.csv",
  "dm_tests.csv",
  "daily_realized_measures.csv",
  "heavy_parameters.csv"
)

all_present <- function(dir) {
  all(
    file.exists(
      file.path(
        dir,
        required_files
      )
    )
  )
}

if (!all_present(DATA_DIR)) {
  if (file.exists(ZIP_FILE)) {
    message(
      "Input folder not found; extracting ",
      ZIP_FILE,
      "..."
    )

    temp_root <- file.path(
      tempdir(),
      "btc_rv_horserace_viz"
    )

    dir.create(
      temp_root,
      recursive = TRUE,
      showWarnings = FALSE
    )

    utils::unzip(
      ZIP_FILE,
      exdir = temp_root
    )

    candidates <- c(
      file.path(
        temp_root,
        "btc_rv_horserace"
      ),
      temp_root
    )

    found <- candidates[
      vapply(
        candidates,
        all_present,
        logical(1)
      )
    ]

    if (length(found) == 0L) {
      stop(
        "ZIP extracted, but required CSV files were not found."
      )
    }

    DATA_DIR <- found[1L]
    OUT_DIR <- file.path(
      DATA_DIR,
      "viz"
    )
  } else {
    stop(
      "Could not find input files in: ",
      DATA_DIR,
      "\nAlso could not find: ",
      ZIP_FILE
    )
  }
}

dir.create(
  OUT_DIR,
  recursive = TRUE,
  showWarnings = FALSE
)

metrics <- readr::read_csv(
  file.path(
    DATA_DIR,
    "metrics.csv"
  ),
  show_col_types = FALSE
)

forecasts <- readr::read_csv(
  file.path(
    DATA_DIR,
    "forecasts.csv"
  ),
  show_col_types = FALSE
)

bootstrap <- readr::read_csv(
  file.path(
    DATA_DIR,
    "bootstrap_tests.csv"
  ),
  show_col_types = FALSE
)

dm <- readr::read_csv(
  file.path(
    DATA_DIR,
    "dm_tests.csv"
  ),
  show_col_types = FALSE
)

daily <- readr::read_csv(
  file.path(
    DATA_DIR,
    "daily_realized_measures.csv"
  ),
  show_col_types = FALSE
)

heavy <- readr::read_csv(
  file.path(
    DATA_DIR,
    "heavy_parameters.csv"
  ),
  show_col_types = FALSE
)

forecasts$origin_date <- as.Date(
  forecasts$origin_date
)

daily$date <- as.Date(
  daily$date
)

heavy$origin_date <- as.Date(
  heavy$origin_date
)


# ==============================================================================
# 3. LABELS / THEME
# ==============================================================================

model_label <- function(x) {
  dplyr::recode(
    x,
    "REALGARCH" = "Realized-GARCH",
    "HARQ" = "HARQ",
    "HARQ_F" = "HARQ-F",
    "HEAVY_RM" = "HEAVY-RM",
    "HAR_J" = "HAR-J",
    "HAR_RV" = "HAR-RV",
    "GARCH_11" = "GARCH(1,1)",
    .default = x
  )
}

HORIZON_LABELS <- c(
  "1" = "1 day",
  "5" = "5 days",
  "10" = "10 days"
)

theme_editorial <- function(base_size = 12) {
  ggplot2::theme_minimal(
    base_size = base_size,
    base_family = "sans"
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(
        fill = PAPER,
        color = NA
      ),
      panel.background = ggplot2::element_rect(
        fill = PAPER,
        color = NA
      ),
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        color = GRID,
        linewidth = 0.35
      ),
      axis.title = ggplot2::element_text(
        color = INK,
        face = "bold"
      ),
      axis.text = ggplot2::element_text(
        color = MUTED
      ),
      plot.title = ggplot2::element_text(
        color = INK,
        face = "bold",
        size = base_size * 1.65,
        margin = ggplot2::margin(
          b = 6
        )
      ),
      plot.subtitle = ggplot2::element_text(
        color = MUTED,
        size = base_size * 1.02,
        lineheight = 1.15,
        margin = ggplot2::margin(
          b = 14
        )
      ),
      plot.caption = ggplot2::element_text(
        color = MUTED,
        size = base_size * 0.78,
        hjust = 0,
        margin = ggplot2::margin(
          t = 12
        )
      ),
      strip.text = ggplot2::element_text(
        color = INK,
        face = "bold",
        size = base_size * 1.05
      ),
      strip.background = ggplot2::element_blank(),
      legend.title = ggplot2::element_blank(),
      legend.text = ggplot2::element_text(
        color = INK
      ),
      legend.position = "bottom",
      plot.margin = ggplot2::margin(
        18,
        20,
        16,
        20
      )
    )
}

save_plot <- function(
    filename,
    plot,
    width = FIG_WIDTH,
    height = FIG_HEIGHT
) {
  ggplot2::ggsave(
    filename = file.path(
      OUT_DIR,
      filename
    ),
    plot = plot,
    width = width,
    height = height,
    dpi = FIG_DPI,
    bg = PAPER
  )
}


# ==============================================================================
# 4. DERIVED DATA
# ==============================================================================

metrics <- metrics |>
  dplyr::mutate(
    model_pretty = model_label(model),
    horizon_pretty = factor(
      as.character(horizon),
      levels = c(
        "1",
        "5",
        "10"
      ),
      labels = c(
        "1 day",
        "5 days",
        "10 days"
      )
    )
  )

har_ref <- metrics |>
  dplyr::filter(
    model == "HAR_RV"
  ) |>
  dplyr::select(
    horizon,
    har_qlike = QLIKE
  )

metric_rel <- metrics |>
  dplyr::left_join(
    har_ref,
    by = "horizon"
  ) |>
  dplyr::mutate(
    improvement_vs_har_pct =
      100 *
      (
        har_qlike -
          QLIKE
      ) /
      har_qlike
  )

# Best model at each horizon.
winners <- metrics |>
  dplyr::group_by(
    horizon
  ) |>
  dplyr::slice_min(
    QLIKE,
    n = 1,
    with_ties = FALSE
  ) |>
  dplyr::ungroup()

# HARQ improvement against HAR-RV.
harq_improvement <- metric_rel |>
  dplyr::filter(
    model == "HARQ"
  ) |>
  dplyr::arrange(
    horizon
  )


# ==============================================================================
# 5. 00 — RESEARCH COVER
# ==============================================================================

cover_data <- winners |>
  dplyr::arrange(
    horizon
  )

cover_text <- paste0(
  model_label(
    cover_data$model
  ),
  "\nQLIKE ",
  sprintf(
    "%.3f",
    cover_data$QLIKE
  )
)

cover <- ggplot2::ggplot() +
  ggplot2::annotate(
    "rect",
    xmin = -Inf,
    xmax = Inf,
    ymin = -Inf,
    ymax = Inf,
    fill = "#12212B"
  ) +
  ggplot2::annotate(
    "text",
    x = 0.05,
    y = 0.90,
    label = "Bitcoin realized-volatility forecasting",
    hjust = 0,
    color = WHITE,
    size = 8.2,
    fontface = "bold"
  ) +
  ggplot2::annotate(
    "text",
    x = 0.05,
    y = 0.81,
    label = "A high-frequency OOS horse race using Binance 5-minute data",
    hjust = 0,
    color = "#B8C4CC",
    size = 4.2
  ) +
  ggplot2::annotate(
    "text",
    x = c(
      0.10,
      0.41,
      0.72
    ),
    y = 0.62,
    label = c(
      "1-DAY WINNER",
      "5-DAY WINNER",
      "10-DAY WINNER"
    ),
    hjust = 0,
    color = "#9FB0BC",
    size = 3.4,
    fontface = "bold"
  ) +
  ggplot2::annotate(
    "text",
    x = c(
      0.10,
      0.41,
      0.72
    ),
    y = 0.49,
    label = cover_text,
    hjust = 0,
    color = c(
      COLORS[
        cover_data$model
      ]
    ),
    size = 5.2,
    fontface = "bold",
    lineheight = 1.0
  ) +
  ggplot2::annotate(
    "segment",
    x = 0.05,
    xend = 0.95,
    y = 0.34,
    yend = 0.34,
    color = "#38505E",
    linewidth = 0.7
  ) +
  ggplot2::annotate(
    "text",
    x = 0.05,
    y = 0.23,
    label = paste0(
      "HARQ improves on HAR-RV by ",
      paste0(
        sprintf(
          "%.1f%%",
          harq_improvement$improvement_vs_har_pct
        ),
        collapse = " / "
      ),
      " at 1 / 5 / 10 days."
    ),
    hjust = 0,
    color = WHITE,
    size = 4.5,
    fontface = "bold"
  ) +
  ggplot2::annotate(
    "text",
    x = 0.05,
    y = 0.12,
    label = paste0(
      "Walk-forward OOS observations per horizon: ",
      max(
        metrics$n,
        na.rm = TRUE
      ),
      "  •  Lower QLIKE is better"
    ),
    hjust = 0,
    color = "#9FB0BC",
    size = 3.5
  ) +
  ggplot2::coord_cartesian(
    xlim = c(
      0,
      1
    ),
    ylim = c(
      0,
      1
    ),
    clip = "off"
  ) +
  ggplot2::theme_void() +
  ggplot2::theme(
    plot.background = ggplot2::element_rect(
      fill = "#12212B",
      color = NA
    ),
    plot.margin = ggplot2::margin(
      30,
      30,
      30,
      30
    )
  )

save_plot(
  "00_research_cover.png",
  cover,
  width = 14,
  height = 8
)


# ==============================================================================
# 6. 01 — QLIKE LEADERBOARD
# ==============================================================================

leaderboard <- metrics |>
  dplyr::group_by(
    horizon_pretty
  ) |>
  dplyr::mutate(
    rank = rank(
      QLIKE,
      ties.method = "first"
    ),
    model_order = forcats::fct_reorder(
      model_pretty,
      -QLIKE
    )
  ) |>
  dplyr::ungroup()

p_leader <- ggplot2::ggplot(
  leaderboard,
  ggplot2::aes(
    x = QLIKE,
    y = forcats::fct_reorder(
      model_pretty,
      -QLIKE
    ),
    color = model
  )
) +
  ggplot2::geom_segment(
    ggplot2::aes(
      x = 0,
      xend = QLIKE,
      yend = forcats::fct_reorder(
        model_pretty,
        -QLIKE
      )
    ),
    color = "#D8D4CA",
    linewidth = 1.0
  ) +
  ggplot2::geom_point(
    ggplot2::aes(
      alpha = ifelse(
        model %in% c("REALGARCH", "HARQ"),
        "focus",
        "secondary"
      )
    ),
    size = 4.8
  ) +
  ggplot2::scale_alpha_manual(
    values = c(
      "focus" = 1.0,
      "secondary" = 0.72
    ),
    guide = "none"
  ) +
  ggplot2::geom_text(
    ggplot2::aes(
      label = sprintf(
        "%.3f",
        QLIKE
      )
    ),
    hjust = -0.35,
    color = INK,
    size = 3.5,
    fontface = "bold"
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    scales = "free_x",
    nrow = 1
  ) +
  ggplot2::scale_color_manual(
    values = COLORS,
    guide = "none"
  ) +
  ggplot2::scale_x_continuous(
    expand = ggplot2::expansion(
      mult = c(
        0,
        0.15
      )
    )
  ) +
  ggplot2::labs(
    title = "Who forecasts Bitcoin volatility best?",
    subtitle = "Out-of-sample QLIKE by forecast horizon. The left-most point wins.",
    x = "QLIKE loss ↓",
    y = NULL,
    caption = "BTCUSDT • Binance 5-minute realized variance • walk-forward estimation"
  ) +
  theme_editorial(
    12
  )

save_plot(
  "01_qlike_leaderboard.png",
  p_leader,
  width = 15,
  height = 7.5
)


# ==============================================================================
# 7. 02 — RELATIVE QLIKE HEATMAP
# ==============================================================================

heat <- metric_rel |>
  dplyr::mutate(
    horizon_pretty = factor(
      as.character(horizon),
      levels = c(
        "1",
        "5",
        "10"
      ),
      labels = c(
        "1 day",
        "5 days",
        "10 days"
      )
    ),
    model_pretty = factor(
      model_label(model),
      levels = rev(
        model_label(
          c(
            "REALGARCH",
            "HARQ",
            "HARQ_F",
            "HEAVY_RM",
            "HAR_J",
            "HAR_RV",
            "GARCH_11"
          )
        )
      )
    ),
    label = ifelse(
      abs(
        improvement_vs_har_pct
      ) < 0.05,
      "0.0%",
      sprintf(
        "%+.1f%%",
        improvement_vs_har_pct
      )
    )
  )

lim <- max(
  abs(
    heat$improvement_vs_har_pct
  ),
  na.rm = TRUE
)

p_heat <- ggplot2::ggplot(
  heat,
  ggplot2::aes(
    x = horizon_pretty,
    y = model_pretty,
    fill = improvement_vs_har_pct
  )
) +
  ggplot2::geom_tile(
    color = PAPER,
    linewidth = 2.2,
    width = 0.97,
    height = 0.92
  ) +
  ggplot2::geom_text(
    ggplot2::aes(
      label = label
    ),
    color = INK,
    fontface = "bold",
    size = 4.2
  ) +
  ggplot2::scale_fill_gradient2(
    low = "#D55E00",
    mid = "#F5F3EE",
    high = "#0072B2",
    midpoint = 0,
    limits = c(
      -lim,
      lim
    ),
    labels = function(x) {
      paste0(
        sprintf(
          "%+.0f",
          x
        ),
        "%"
      )
    }
  ) +
  ggplot2::labs(
    title = "How much does each model improve on plain HAR-RV?",
    subtitle = "Positive values mean lower QLIKE than HAR-RV; blue is better, orange is worse.",
    x = NULL,
    y = NULL,
    fill = "QLIKE improvement",
    caption = "Relative improvement = 100 × (QLIKE_HAR-RV − QLIKE_model) / QLIKE_HAR-RV"
  ) +
  theme_editorial(
    12
  ) +
  ggplot2::theme(
    panel.grid = ggplot2::element_blank(),
    legend.position = "bottom"
  )

save_plot(
  "02_relative_qlike_heatmap.png",
  p_heat,
  width = 11,
  height = 7.5
)


# ==============================================================================
# 8. DAILY QLIKE HELPERS
# ==============================================================================

qlike <- function(
    actual,
    forecast,
    eps = 1e-12
) {
  actual <- pmax(
    actual,
    eps
  )

  forecast <- pmax(
    forecast,
    eps
  )

  ratio <- actual /
    forecast

  ratio -
    log(
      ratio
    ) -
    1
}

daily_loss <- forecasts |>
  dplyr::filter(
    is.finite(
      actual_rv
    ),
    is.finite(
      forecast_rv
    )
  ) |>
  dplyr::mutate(
    qlike = qlike(
      actual_rv,
      forecast_rv
    )
  )


# ==============================================================================
# 9. 03 — CUMULATIVE QLIKE VS HAR-RV
# ==============================================================================

har_daily <- daily_loss |>
  dplyr::filter(
    model == "HAR_RV"
  ) |>
  dplyr::select(
    origin_date,
    horizon,
    har_qlike = qlike
  )

cum_vs_har <- daily_loss |>
  dplyr::filter(
    model %in% FOCUS_MODELS,
    model != "HAR_RV"
  ) |>
  dplyr::left_join(
    har_daily,
    by = c(
      "origin_date",
      "horizon"
    )
  ) |>
  dplyr::mutate(
    diff = qlike -
      har_qlike
  ) |>
  dplyr::arrange(
    horizon,
    model,
    origin_date
  ) |>
  dplyr::group_by(
    horizon,
    model
  ) |>
  dplyr::mutate(
    cumulative_diff = cumsum(
      diff
    )
  ) |>
  dplyr::ungroup() |>
  dplyr::mutate(
    horizon_pretty = factor(
      as.character(horizon),
      levels = c(
        "1",
        "5",
        "10"
      ),
      labels = c(
        "1 day",
        "5 days",
        "10 days"
      )
    ),
    model_pretty = model_label(
      model
    )
  )

p_cum <- ggplot2::ggplot(
  cum_vs_har,
  ggplot2::aes(
    x = origin_date,
    y = cumulative_diff,
    color = model
  )
) +
  ggplot2::geom_hline(
    yintercept = 0,
    color = "#AAA59B",
    linewidth = 0.5
  ) +
  ggplot2::geom_line(
    ggplot2::aes(
      linewidth = ifelse(
        model %in% c("REALGARCH", "HARQ"),
        "focus",
        "secondary"
      ),
      alpha = ifelse(
        model %in% c("REALGARCH", "HARQ"),
        "focus",
        "secondary"
      )
    )
  ) +
  ggplot2::scale_linewidth_manual(
    values = c(
      "focus" = 1.05,
      "secondary" = 0.65
    ),
    guide = "none"
  ) +
  ggplot2::scale_alpha_manual(
    values = c(
      "focus" = 1.0,
      "secondary" = 0.55
    ),
    guide = "none"
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    scales = "free_y",
    ncol = 1
  ) +
  ggplot2::scale_color_manual(
    values = COLORS,
    labels = function(x) {
      model_label(
        x
      )
    }
  ) +
  ggplot2::scale_x_date(
    date_breaks = "3 months",
    date_labels = "%b\n%Y",
    expand = ggplot2::expansion(
      mult = c(
        0,
        0.01
      )
    )
  ) +
  ggplot2::labs(
    title = "The advantage is persistent—not one lucky forecast",
    subtitle = "Cumulative QLIKE difference versus HAR-RV. Falling lines indicate cumulative outperformance.",
    x = NULL,
    y = "Cumulative QLIKE difference",
    caption = "A steadily declining line is more convincing than a result driven by one isolated volatility event."
  ) +
  theme_editorial(
    11
  )

save_plot(
  "03_cumulative_qlike_vs_har.png",
  p_cum,
  width = 14,
  height = 10
)


# ==============================================================================
# 10. 04 — REALIZED-GARCH VS HARQ HEAD-TO-HEAD
# ==============================================================================

head_a <- daily_loss |>
  dplyr::filter(
    model == "REALGARCH"
  ) |>
  dplyr::select(
    origin_date,
    horizon,
    actual_rv,
    realgarch_qlike = qlike
  )

head_b <- daily_loss |>
  dplyr::filter(
    model == "HARQ"
  ) |>
  dplyr::select(
    origin_date,
    horizon,
    harq_qlike = qlike
  )

head <- head_a |>
  dplyr::inner_join(
    head_b,
    by = c(
      "origin_date",
      "horizon"
    )
  ) |>
  dplyr::mutate(
    diff = realgarch_qlike -
      harq_qlike
  ) |>
  dplyr::arrange(
    horizon,
    origin_date
  ) |>
  dplyr::group_by(
    horizon
  ) |>
  dplyr::mutate(
    cumulative_diff = cumsum(
      diff
    )
  ) |>
  dplyr::ungroup() |>
  dplyr::mutate(
    horizon_pretty = factor(
      as.character(horizon),
      levels = c(
        "1",
        "5",
        "10"
      ),
      labels = c(
        "1 day",
        "5 days",
        "10 days"
      )
    )
  )

p_head <- ggplot2::ggplot(
  head,
  ggplot2::aes(
    origin_date,
    cumulative_diff
  )
) +
  ggplot2::geom_hline(
    yintercept = 0,
    color = "#9F9A90",
    linewidth = 0.55
  ) +
  ggplot2::geom_area(
    ggplot2::aes(
      fill = cumulative_diff < 0
    ),
    alpha = 0.16
  ) +
  ggplot2::geom_line(
    color = COLORS[
      "REALGARCH"
    ],
    linewidth = 1.05
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    scales = "free_y",
    nrow = 1
  ) +
  ggplot2::scale_fill_manual(
    values = c(
      "TRUE" = COLORS[
        "REALGARCH"
      ],
      "FALSE" = COLORS[
        "HARQ"
      ]
    ),
    guide = "none"
  ) +
  ggplot2::scale_x_date(
    date_breaks = "4 months",
    date_labels = "%b\n%Y"
  ) +
  ggplot2::labs(
    title = "Realized-GARCH vs HARQ: the direct head-to-head",
    subtitle = "Cumulative QLIKE(Realized-GARCH) − QLIKE(HARQ). Below zero favors Realized-GARCH.",
    x = NULL,
    y = "Cumulative loss difference",
    caption = "This chart is descriptive; formal paired inference should accompany any claim of superiority."
  ) +
  theme_editorial(
    11
  )

save_plot(
  "04_realgarch_vs_harq.png",
  p_head,
  width = 14.5,
  height = 6.5
)


# ==============================================================================
# 11. 05 — FORECAST VS REALIZED
# ==============================================================================

forecast_focus <- forecasts |>
  dplyr::filter(
    horizon == 1,
    model %in% c(
      "REALGARCH",
      "HARQ",
      "HAR_RV"
    )
  ) |>
  dplyr::arrange(
    model,
    origin_date
  ) |>
  dplyr::group_by(
    model
  ) |>
  dplyr::mutate(
    forecast_vol =
      sqrt(
        pmax(
          forecast_rv,
          0
        )
      ),
    forecast_vol_roll =
      zoo::rollmean(
        forecast_vol,
        k = ROLLING_DAYS,
        fill = NA,
        align = "right"
      )
  ) |>
  dplyr::ungroup()

actual_focus <- forecasts |>
  dplyr::filter(
    horizon == 1
  ) |>
  dplyr::distinct(
    origin_date,
    actual_rv
  ) |>
  dplyr::arrange(
    origin_date
  ) |>
  dplyr::mutate(
    actual_vol =
      sqrt(
        pmax(
          actual_rv,
          0
        )
      ),
    actual_vol_roll =
      zoo::rollmean(
        actual_vol,
        k = ROLLING_DAYS,
        fill = NA,
        align = "right"
      )
  )

p_forecast <- ggplot2::ggplot() +
  ggplot2::geom_line(
    data = actual_focus,
    ggplot2::aes(
      origin_date,
      actual_vol_roll
    ),
    color = "#111111",
    linewidth = 1.15
  ) +
  ggplot2::geom_line(
    data = forecast_focus,
    ggplot2::aes(
      origin_date,
      forecast_vol_roll,
      color = model
    ),
    linewidth = 0.85,
    alpha = 0.92
  ) +
  ggplot2::scale_color_manual(
    values = COLORS,
    labels = function(x) {
      model_label(
        x
      )
    }
  ) +
  ggplot2::scale_x_date(
    date_breaks = "3 months",
    date_labels = "%b\n%Y"
  ) +
  ggplot2::labs(
    title = "Can the models track the volatility state?",
    subtitle = paste0(
      ROLLING_DAYS,
      "-day rolling average; black is realized volatility, colors are model forecasts"
    ),
    x = NULL,
    y = "Daily volatility (%)",
    caption = "Black = subsequently realized volatility. Colored lines = forecasts formed using information available at the origin."
  ) +
  theme_editorial(
    12
  )

save_plot(
  "05_forecast_vs_realized.png",
  p_forecast,
  width = 14,
  height = 7
)


# ==============================================================================
# 12. 06 — BOOTSTRAP FOREST PLOT
# ==============================================================================

forest_keep <- bootstrap |>
  dplyr::filter(
    loss == "QLIKE",
    (
      model_B == "HAR_RV" &
        model_A %in% c(
          "HARQ",
          "HARQ_F",
          "HEAVY_RM",
          "REALGARCH"
        )
    ) |
      (
        model_B == "GARCH_11" &
          model_A %in% c(
            "HARQ",
            "HEAVY_RM",
            "REALGARCH"
          )
      )
  ) |>
  dplyr::mutate(
    comparison = paste0(
      model_label(
        model_A
      ),
      "  vs  ",
      model_label(
        model_B
      )
    ),
    significant_better =
      ci_high < 0,
    significant_worse =
      ci_low > 0,
    evidence = dplyr::case_when(
      significant_better ~ "A better",
      significant_worse ~ "A worse",
      TRUE ~ "Inconclusive"
    ),
    horizon_pretty = factor(
      as.character(horizon),
      levels = c(
        "1",
        "5",
        "10"
      ),
      labels = c(
        "1 day",
        "5 days",
        "10 days"
      )
    )
  )

p_forest <- ggplot2::ggplot(
  forest_keep,
  ggplot2::aes(
    x = mean_loss_diff_A_minus_B,
    y = forcats::fct_rev(
      factor(
        comparison
      )
    ),
    color = evidence
  )
) +
  ggplot2::geom_vline(
    xintercept = 0,
    color = "#918D84",
    linewidth = 0.6
  ) +
  ggplot2::geom_errorbar(
    ggplot2::aes(
      xmin = ci_low,
      xmax = ci_high
    ),
    width = 0,
    linewidth = 1.0
  ) +
  ggplot2::geom_point(
    size = 3.7
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    scales = "free_x",
    nrow = 1
  ) +
  ggplot2::scale_color_manual(
    values = c(
      "A better" = POS,
      "A worse" = NEG,
      "Inconclusive" = NEUTRAL
    )
  ) +
  ggplot2::labs(
    title = "Which improvements survive block-bootstrap uncertainty?",
    subtitle = "Mean QLIKE loss difference with 95% moving-block bootstrap intervals. Left of zero favors model A.",
    x = "QLIKE(A) − QLIKE(B)",
    y = NULL,
    caption = "Intervals fully below zero provide the cleanest evidence of lower forecast loss."
  ) +
  theme_editorial(
    10.5
  )

save_plot(
  "06_bootstrap_forest.png",
  p_forest,
  width = 16,
  height = 8.5
)


# ==============================================================================
# 13. 07 — PERFORMANCE BY VOLATILITY REGIME
# ==============================================================================

regime_base <- daily_loss |>
  dplyr::filter(
    model %in% c(
      "REALGARCH",
      "HARQ",
      "HAR_RV",
      "GARCH_11"
    )
  ) |>
  dplyr::group_by(
    horizon
  ) |>
  dplyr::mutate(
    regime = dplyr::ntile(
      actual_rv,
      4L
    ),
    regime = factor(
      regime,
      levels = 1:4,
      labels = c(
        "Low",
        "Normal",
        "High",
        "Extreme"
      )
    )
  ) |>
  dplyr::ungroup()

regime_perf <- regime_base |>
  dplyr::group_by(
    horizon,
    model,
    regime
  ) |>
  dplyr::summarise(
    QLIKE = mean(
      qlike,
      na.rm = TRUE
    ),
    .groups = "drop"
  ) |>
  dplyr::group_by(
    horizon,
    regime
  ) |>
  dplyr::mutate(
    best_qlike = min(
      QLIKE,
      na.rm = TRUE
    ),
    excess_vs_best =
      QLIKE -
      best_qlike
  ) |>
  dplyr::ungroup() |>
  dplyr::mutate(
    horizon_pretty = factor(
      as.character(horizon),
      levels = c(
        "1",
        "5",
        "10"
      ),
      labels = c(
        "1 day",
        "5 days",
        "10 days"
      )
    ),
    model_pretty = factor(
      model_label(
        model
      ),
      levels = rev(
        model_label(
          c(
            "REALGARCH",
            "HARQ",
            "HAR_RV",
            "GARCH_11"
          )
        )
      )
    )
  )

p_regime <- ggplot2::ggplot(
  regime_perf,
  ggplot2::aes(
    regime,
    model_pretty,
    fill = excess_vs_best
  )
) +
  ggplot2::geom_tile(
    color = PAPER,
    linewidth = 1.8
  ) +
  ggplot2::geom_text(
    ggplot2::aes(
      label = sprintf(
        "%.3f",
        QLIKE
      )
    ),
    size = 3.35,
    fontface = "bold",
    color = INK
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    nrow = 1
  ) +
  ggplot2::scale_fill_gradient(
    low = "#EAF3F8",
    high = "#D55E00",
    labels = scales::label_number(
      accuracy = 0.01
    )
  ) +
  ggplot2::labs(
    title = "Where does each model actually win?",
    subtitle = "QLIKE by ex-post realized-volatility quartile. Pale cells are closest to the best model in that regime.",
    x = "Realized-volatility regime",
    y = NULL,
    fill = "Excess QLIKE",
    caption = "Regimes are formed separately within each horizon from the realized future variance."
  ) +
  theme_editorial(
    10.5
  ) +
  ggplot2::theme(
    panel.grid = ggplot2::element_blank()
  )

save_plot(
  "07_regime_performance.png",
  p_regime,
  width = 15,
  height = 7
)


# ==============================================================================
# 14. 08 — HEAVY PARAMETER EVOLUTION
# ==============================================================================

heavy_long <- heavy |>
  dplyr::select(
    origin_date,
    alpha,
    beta,
    rho
  ) |>
  tidyr::pivot_longer(
    cols = c(
      alpha,
      beta,
      rho
    ),
    names_to = "parameter",
    values_to = "value"
  ) |>
  dplyr::mutate(
    parameter = factor(
      parameter,
      levels = c(
        "alpha",
        "beta",
        "rho"
      ),
      labels = c(
        expression(alpha),
        expression(beta),
        expression(alpha + beta)
      )
    )
  )

p_heavy <- ggplot2::ggplot(
  heavy_long,
  ggplot2::aes(
    origin_date,
    value,
    color = parameter
  )
) +
  ggplot2::geom_line(
    linewidth = 0.9
  ) +
  ggplot2::scale_color_manual(
    values = c(
      "#D55E00",
      "#CC79A7",
      "#0072B2"
    ),
    labels = c(
      "α: reaction to latest RV",
      "β: persistence of latent state",
      "α + β: total persistence"
    )
  ) +
  ggplot2::scale_x_date(
    date_breaks = "3 months",
    date_labels = "%b\n%Y"
  ) +
  ggplot2::labs(
    title = "What HEAVY is learning through time",
    subtitle = "The 1-day model reacts strongly to the latest realized variance; persistence varies through the OOS window.",
    x = NULL,
    y = "Parameter estimate",
    caption = "HEAVY-RM: mₜ = ω + α·RVₜ₋₁ + β·mₜ₋₁"
  ) +
  theme_editorial(
    12
  )

save_plot(
  "08_heavy_parameter_evolution.png",
  p_heavy,
  width = 13,
  height = 6.5
)


# ==============================================================================
# 15. 09 — RESEARCH DASHBOARD
# ==============================================================================

# Compact versions of leaderboard / head-to-head / forest for one-page summary.

leader_dash <- metrics |>
  dplyr::filter(
    model %in% c(
      "REALGARCH",
      "HARQ",
      "HEAVY_RM",
      "HAR_RV",
      "GARCH_11"
    )
  )

p1 <- ggplot2::ggplot(
  leader_dash,
  ggplot2::aes(
    x = QLIKE,
    y = forcats::fct_reorder(
      model_label(
        model
      ),
      -QLIKE
    ),
    color = model
  )
) +
  ggplot2::geom_point(
    size = 4.2
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    nrow = 1,
    scales = "free_x"
  ) +
  ggplot2::scale_color_manual(
    values = COLORS,
    guide = "none"
  ) +
  ggplot2::labs(
    title = "QLIKE leaderboard",
    x = "Lower is better",
    y = NULL
  ) +
  theme_editorial(
    9.5
  ) +
  ggplot2::theme(
    plot.subtitle = ggplot2::element_blank(),
    plot.caption = ggplot2::element_blank()
  )

p2 <- ggplot2::ggplot(
  head,
  ggplot2::aes(
    origin_date,
    cumulative_diff
  )
) +
  ggplot2::geom_hline(
    yintercept = 0,
    color = "#A6A095",
    linewidth = 0.45
  ) +
  ggplot2::geom_line(
    color = COLORS[
      "REALGARCH"
    ],
    linewidth = 0.85
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    nrow = 1,
    scales = "free_y"
  ) +
  ggplot2::labs(
    title = "Realized-GARCH vs HARQ",
    x = NULL,
    y = "Cumulative Δ QLIKE"
  ) +
  theme_editorial(
    9.5
  ) +
  ggplot2::theme(
    plot.subtitle = ggplot2::element_blank(),
    plot.caption = ggplot2::element_blank(),
    legend.position = "none"
  )

forest_dash <- forest_keep |>
  dplyr::filter(
    model_B == "HAR_RV"
  )

p3 <- ggplot2::ggplot(
  forest_dash,
  ggplot2::aes(
    mean_loss_diff_A_minus_B,
    forcats::fct_rev(
      comparison
    ),
    color = evidence
  )
) +
  ggplot2::geom_vline(
    xintercept = 0,
    color = "#99948A"
  ) +
  ggplot2::geom_errorbar(
    ggplot2::aes(
      xmin = ci_low,
      xmax = ci_high
    ),
    width = 0,
    linewidth = 0.8
  ) +
  ggplot2::geom_point(
    size = 2.8
  ) +
  ggplot2::facet_wrap(
    ~ horizon_pretty,
    scales = "free_x",
    nrow = 1
  ) +
  ggplot2::scale_color_manual(
    values = c(
      "A better" = POS,
      "A worse" = NEG,
      "Inconclusive" = NEUTRAL
    ),
    guide = "none"
  ) +
  ggplot2::labs(
    title = "Bootstrap evidence vs HAR-RV",
    x = "QLIKE difference",
    y = NULL
  ) +
  theme_editorial(
    9.5
  ) +
  ggplot2::theme(
    plot.subtitle = ggplot2::element_blank(),
    plot.caption = ggplot2::element_blank()
  )

dashboard <- (
  p1 /
    p2 /
    p3
) +
  patchwork::plot_annotation(
    title = "Bitcoin realized-volatility forecasting",
    subtitle = "Realized-GARCH leads on raw QLIKE; HARQ delivers the cleanest robust benchmark improvement.",
    caption = "Binance BTCUSDT 5-minute data • QLIKE evaluation • moving-block bootstrap",
    theme = ggplot2::theme(
      plot.background = ggplot2::element_rect(
        fill = PAPER,
        color = NA
      ),
      plot.title = ggplot2::element_text(
        face = "bold",
        size = 24,
        color = INK
      ),
      plot.subtitle = ggplot2::element_text(
        size = 13,
        color = MUTED
      ),
      plot.caption = ggplot2::element_text(
        size = 9,
        color = MUTED,
        hjust = 0
      )
    )
  ) &
  ggplot2::theme(
    plot.background = ggplot2::element_rect(
      fill = PAPER,
      color = NA
    )
  )

save_plot(
  "09_research_dashboard.png",
  dashboard,
  width = 16,
  height = 17
)


# ==============================================================================
# 16. EXPORT A SMALL VIZ SUMMARY TABLE
# ==============================================================================

viz_summary <- metric_rel |>
  dplyr::select(
    horizon,
    model,
    RMSE,
    MAE,
    QLIKE,
    improvement_vs_har_pct
  ) |>
  dplyr::arrange(
    horizon,
    QLIKE
  )

readr::write_csv(
  viz_summary,
  file.path(
    OUT_DIR,
    "viz_summary.csv"
  )
)


# ==============================================================================
# 17. CONSOLE
# ==============================================================================

cat(
  "\n============================================================\n"
)

cat(
  "AESTHETIC VISUAL PACK CREATED\n"
)

cat(
  "============================================================\n"
)

cat(
  "Output folder: ",
  normalizePath(
    OUT_DIR,
    winslash = "/",
    mustWork = FALSE
  ),
  "\n\n",
  sep = ""
)

cat(
  "Best figures for sharing:\n",
  "  00_research_cover.png\n",
  "  02_relative_qlike_heatmap.png\n",
  "  04_realgarch_vs_harq.png\n",
  "  06_bootstrap_forest.png\n",
  "  09_research_dashboard.png\n\n",
  sep = ""
)

cat(
  "All figures are saved at ",
  FIG_DPI,
  " DPI.\n",
  sep = ""
)
