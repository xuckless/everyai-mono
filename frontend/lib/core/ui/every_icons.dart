import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons_300.dart';

import '../platform/platform_kind.dart';

/// App icons: Lucide line icons (MIT/ISC) at the light stroke the EveryAI kit
/// draws, the same on every platform.
enum EveryIcon {
  newChat(LucideIcons300.squarePen),
  send(LucideIcons300.arrowUp),
  stop(LucideIcons300.square),
  menu(LucideIcons300.menu),
  sidebar(LucideIcons300.panelLeft),
  settings(LucideIcons300.settings),
  search(LucideIcons300.search),
  copy(LucideIcons300.copy),
  retry(LucideIcons300.rotateCw),
  delete(LucideIcons300.trash2),
  pin(LucideIcons300.pin),
  models(LucideIcons300.layers),
  spark(LucideIcons300.sparkles),
  account(LucideIcons300.circleUser),
  add(LucideIcons300.plus),
  check(LucideIcons300.check),
  close(LucideIcons300.x),
  attach(LucideIcons300.paperclip),
  mention(LucideIcons300.atSign),
  chevronDown(LucideIcons300.chevronDown),
  chevronUp(LucideIcons300.chevronUp),
  chevronUpDown(LucideIcons300.chevronsUpDown),
  more(LucideIcons300.ellipsis),
  chat(LucideIcons300.messagesSquare),
  edit(LucideIcons300.pencil),
  projects(LucideIcons300.folder),
  artifacts(LucideIcons300.shapes),
  globe(LucideIcons300.globe),
  openPanel(LucideIcons300.panelRight),
  chevronLeft(LucideIcons300.chevronLeft),
  chevronRight(LucideIcons300.chevronRight),
  download(LucideIcons300.download),
  external(LucideIcons300.externalLink),
  document(LucideIcons300.fileText),
  code(LucideIcons300.code),
  quiz(LucideIcons300.listChecks),
  cards(LucideIcons300.galleryVerticalEnd),
  slides(LucideIcons300.presentation),
  chart(LucideIcons300.chartColumn),
  diagram(LucideIcons300.workflow),
  image(LucideIcons300.image),
  play(LucideIcons300.circlePlay),
  pause(LucideIcons300.circlePause),
  drawing(LucideIcons300.penLine),
  devices(LucideIcons300.laptop),
  key(LucideIcons300.keyRound),
  card(LucideIcons300.creditCard),
  usage(LucideIcons300.chartNoAxesColumn),
  sun(LucideIcons300.sun),
  moon(LucideIcons300.moon),
  display(LucideIcons300.monitor),
  activity(LucideIcons300.activity),
  minus(LucideIcons300.minus),
  help(LucideIcons300.circleHelp),
  signOut(LucideIcons300.logOut),
  language(LucideIcons300.languages),
  info(LucideIcons300.info),
  shield(LucideIcons300.shieldHalf),
  plug(LucideIcons300.plug),
  skill(LucideIcons300.wandSparkles),
  agents(LucideIcons300.bot),
  command(LucideIcons300.terminal),
  memory(LucideIcons300.lightbulb),
  wrench(LucideIcons300.wrench),
  general(LucideIcons300.slidersHorizontal),
  person(LucideIcons300.user),
  board(LucideIcons300.squareKanban),
  branch(LucideIcons300.gitBranch),
  workflow(LucideIcons300.zap),
  cpu(LucideIcons300.cpu),
  arrowUpRight(LucideIcons300.arrowUpRight);

  const EveryIcon(this.data);

  final IconData data;

  /// Kept for callers that still pass a design language; every language gets the same glyph.
  IconData of(DesignLanguage design) => data;
}
