// How this build is distributed, from its Android flavour (FLUTTER_APP_FLAVOR): the github build updates itself; the
// play build hides the self-updater, because Google Play does the updating. Windows and other builds have no flavour.
import 'package:flutter/services.dart' show appFlavor;

enum Distribution { github, play }

/// The distribution a flavour name means; anything but `play` (no flavour included) is the GitHub build.
Distribution distributionFor(String? flavor) => flavor == 'play' ? Distribution.play : Distribution.github;

/// This build's distribution.
final Distribution buildDistribution = distributionFor(appFlavor);

/// Whether this build has the in-app updater (Settings › App › Updates, the update prompt).
bool get selfUpdates => buildDistribution == Distribution.github;
