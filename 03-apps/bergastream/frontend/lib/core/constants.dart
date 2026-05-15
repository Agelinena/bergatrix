const String kAppName = 'BergaStream';

// Layout breakpoints
const double kMobileBreakpoint = 600;
const double kDesktopBreakpoint = 900;

// Player
const double kMiniPlayerHeight = 64;
const double kPlayerBarHeight = 90;

// Desktop layout
const double kSidebarWidth = 240.0;
const double kNowPlayingWidth = 280.0;

// Animation durations
const Duration kPageTransition = Duration(milliseconds: 250);
const Duration kCardHover = Duration(milliseconds: 150);

// API
const String kApiBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://localhost:8000',
);
