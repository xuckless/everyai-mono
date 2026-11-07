// The scrcpy server EveryAI pushes to Android devices for the live Preview (github.com/Genymobile/scrcpy,
// Apache-2.0): the release's server file and its SHA-256 (the release's SHA256SUMS.txt, checked against our own
// download). The client side is ours (scrcpy_io.dart) and speaks this version's protocol: move them together.

const scrcpyVersion = '5.0.1';
const scrcpyServerUrl = 'https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-server-v5.0.1';
const scrcpyServerSha256 = '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536';
