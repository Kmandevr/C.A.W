// A dialog that becomes a glass bottom sheet on a phone: within thumb reach, and it slides away with a swipe.
import 'package:flutter/material.dart';

import 'glass.dart';

/// Below this width a dialog shows as a bottom sheet.
const double sheetBelowWidth = 600;

/// Shows [builder]'s dialog (usually an [AlertDialog]) as a dialog on a wide screen and as a glass bottom sheet on a
/// phone. In the sheet the dialog's own card is see-through and full width, so the sheet's glass is its surface.
Future<T?> showDialogOrSheet<T>({required BuildContext context, required WidgetBuilder builder}) {
  if (MediaQuery.sizeOf(context).width >= sheetBelowWidth) return showDialog<T>(context: context, builder: builder);
  return showGlassSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) {
      final theme = Theme.of(c);
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: Theme(
          data: theme.copyWith(
            dialogTheme: theme.dialogTheme.copyWith(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              shadowColor: Colors.transparent,
              insetPadding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              alignment: Alignment.bottomCenter,
              shape: const RoundedRectangleBorder(),
            ),
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.8),
              // The dialog's Align would fill the height; the sheet is as tall as the dialog's content.
              child: IntrinsicHeight(child: builder(c)),
            ),
          ),
        ),
      );
    },
  );
}
