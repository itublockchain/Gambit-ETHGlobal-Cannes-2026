module.exports = {
  apps: [{
    name: 'gambit',
    script: 'node_modules/.bin/tsx',
    args: 'src/index.ts',
    cwd: '/opt/gambit',
    env: {
      NODE_ENV: 'production',
    },
    max_restarts: 10,
    restart_delay: 5000,
  }],
};
