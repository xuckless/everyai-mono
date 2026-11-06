/// Fonts the terminal falls back to after Geist Mono, in order. The bundled Nerd Fonts symbols come first, so
/// prompts built with Powerline arrows and Nerd Font icons (oh-my-zsh agnoster, starship, powerlevel10k) draw on
/// every machine, Nerd Font installed or not; the rest are xterm's own defaults.
const terminalFontFallback = [
  'SymbolsNerdFontMono',
  'Menlo',
  'Monaco',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Noto Color Emoji',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];
