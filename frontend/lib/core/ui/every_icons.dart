import 'package:cupertino_ui/cupertino_ui.dart' as c;
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as m;

import '../platform/platform_kind.dart';

/// App icons, mapped to each design language's native glyph set:
/// SF Symbols-style CupertinoIcons on Apple, Segoe Fluent icons on Windows,
/// rounded Material icons on Android, web and Linux.
enum EveryIcon {
  newChat(c.CupertinoIcons.square_pencil, f.FluentIcons.edit, m.Icons.edit_note_rounded),
  send(c.CupertinoIcons.arrow_up_circle_fill, f.FluentIcons.send, m.Icons.arrow_upward_rounded),
  stop(c.CupertinoIcons.stop_circle_fill, f.FluentIcons.circle_stop_solid, m.Icons.stop_rounded),
  menu(c.CupertinoIcons.sidebar_left, f.FluentIcons.global_nav_button, m.Icons.menu_rounded),
  sidebar(c.CupertinoIcons.sidebar_left, f.FluentIcons.open_pane, m.Icons.view_sidebar_outlined),
  settings(c.CupertinoIcons.gear, f.FluentIcons.settings, m.Icons.settings_outlined),
  search(c.CupertinoIcons.search, f.FluentIcons.search, m.Icons.search_rounded),
  copy(c.CupertinoIcons.doc_on_doc, f.FluentIcons.copy, m.Icons.content_copy_rounded),
  retry(c.CupertinoIcons.arrow_clockwise, f.FluentIcons.refresh, m.Icons.refresh_rounded),
  delete(c.CupertinoIcons.trash, f.FluentIcons.delete, m.Icons.delete_outline_rounded),
  pin(c.CupertinoIcons.pin, f.FluentIcons.pinned, m.Icons.push_pin_outlined),
  models(c.CupertinoIcons.square_stack_3d_up, f.FluentIcons.library, m.Icons.apps_rounded),
  spark(c.CupertinoIcons.sparkles, f.FluentIcons.robot, m.Icons.auto_awesome_rounded),
  account(c.CupertinoIcons.person_crop_circle, f.FluentIcons.contact, m.Icons.account_circle_outlined),
  add(c.CupertinoIcons.plus, f.FluentIcons.add, m.Icons.add_rounded),
  check(c.CupertinoIcons.checkmark, f.FluentIcons.accept, m.Icons.check_rounded),
  close(c.CupertinoIcons.xmark, f.FluentIcons.cancel, m.Icons.close_rounded),
  attach(c.CupertinoIcons.paperclip, f.FluentIcons.attach, m.Icons.attach_file_rounded),
  mention(c.CupertinoIcons.at, f.FluentIcons.mail, m.Icons.alternate_email_rounded),
  chevronDown(c.CupertinoIcons.chevron_down, f.FluentIcons.chevron_down, m.Icons.expand_more_rounded),
  more(c.CupertinoIcons.ellipsis, f.FluentIcons.more, m.Icons.more_horiz_rounded),
  chat(c.CupertinoIcons.bubble_left_bubble_right, f.FluentIcons.chat, m.Icons.chat_bubble_outline_rounded),
  edit(c.CupertinoIcons.pencil, f.FluentIcons.edit, m.Icons.edit_outlined),
  projects(c.CupertinoIcons.folder, f.FluentIcons.folder_horizontal, m.Icons.folder_outlined),
  artifacts(c.CupertinoIcons.cube, f.FluentIcons.cube_shape, m.Icons.category_outlined),
  globe(c.CupertinoIcons.globe, f.FluentIcons.globe, m.Icons.public_rounded);

  const EveryIcon(this._apple, this._fluent, this._material);

  final IconData _apple;
  final IconData _fluent;
  final IconData _material;

  IconData of(DesignLanguage design) => switch (design) {
    DesignLanguage.cupertino || DesignLanguage.macos => _apple,
    DesignLanguage.fluent => _fluent,
    DesignLanguage.material || DesignLanguage.adwaita => _material,
  };
}
