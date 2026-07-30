// PM2 launcher for the Next.js server.
//
// Why this exists instead of pointing PM2 at Next's binary with
// `args: "start -p 3000"`:
//
// PM2 6.x appends the ecosystem/config file path to the child process argv.
// `next start [dir]` reads that trailing value as the project directory, so the
// container crash-loops with:
//     No such directory exists as the project root: /app/process.yml
//
// It happens with process.yml and ecosystem.config.js alike, with args given as
// a string or an array, and with or without the `start` subcommand -- there is
// no configuration-side fix. Rewriting argv here makes whatever PM2 appends
// irrelevant, and keeps cluster mode working (PM2 forks this module directly).
process.argv = [
  process.argv[0],
  process.argv[1],
  'start',
  '-p',
  process.env.PORT || '3000',
];

require('next/dist/bin/next');
