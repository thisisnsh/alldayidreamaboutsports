// Site-wide constants. Everything that appears in more than one template and
// would be a bug to get out of step lives here.
export default {
  name: "All Day I Dream About Sports",
  shortName: "Sports Alerts",
  url: "https://alldayidreamaboutsports.com",
  email: "support@alldayidreamaboutsports.com",
  downloadUrl: "https://download.alldayidreamaboutsports.com/latest",
  windowsWaitlist:
    "mailto:support@alldayidreamaboutsports.com?subject=Waitlist%20for%20Windows",
  requires: "macOS 14.0 or later",
  requiresShort: "macOS 14+",
  year: 2026,

  // The background reel. Hosted on the R2 bucket that already fronts the app
  // downloads, so there is no new infrastructure and nothing large in git.
  video: {
    mp4: "https://download.alldayidreamaboutsports.com/promo.mp4",
    webm: "https://download.alldayidreamaboutsports.com/promo.webm",
    poster: "https://download.alldayidreamaboutsports.com/promo-f1.webp",
  },

  // The canonical, addressable video - the thing VideoObject describes.
  // uploadDate is read off the YouTube watch page, never guessed.
  youtube: {
    id: "B75DYFddkV0",
    watch: "https://youtu.be/B75DYFddkV0",
    embed: "https://www.youtube.com/embed/B75DYFddkV0",
    thumb: "https://i.ytimg.com/vi/B75DYFddkV0/maxresdefault.jpg",
    title: "All Day I Dream About Sports | Showcase Aug 2026",
    uploadDate: "2026-08-29T15:03:31-07:00",
    description:
      "A walkthrough of All Day I Dream About Sports on macOS: goal, card and full-time alerts dropping below the MacBook notch, a floating score capsule pinned to a corner, and goal celebrations shared with fans across the globe.",
  },

  // The clubs the footer and the home page crest grid carry, by catalog id.
  // Chosen on search volume, not on the table.
  bigClubs: [
    42, 40, 50, 33, 49, 47, 541, 529, 530, 157, 165, 505, 489, 496, 492, 85,
  ],

  // Every event type the app can alert on, straight out of MatchModels.swift.
  eventTypes: [
    "kickoff",
    "goal",
    "disallowed goal",
    "yellow card",
    "red card",
    "half-time",
    "second half",
    "full-time",
    "extra time",
    "penalty shootout",
    "penalty kick",
    "substitution",
    "VAR decision",
    "celebration tally",
  ],
};
