module.exports = {
  apps: [{
    name: "flowmaster",
    script: "server.js",
    cwd: __dirname,
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: "512M",
    kill_timeout: 10000,
    env: {
      NODE_ENV: "production",
      HOST: process.env.HOST || "0.0.0.0",
      PORT: Number(process.env.PORT || 10089)
    },
    env_production: {
      NODE_ENV: "production"
    }
  }]
}
