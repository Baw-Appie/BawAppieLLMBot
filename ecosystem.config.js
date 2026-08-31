module.exports = {
  apps: [
    {
      name: "BawAppieLLMBot",
      cwd: __dirname,
      script: "./BawAppieLLMBot",
      interpreter: "none",
      args: "serve --env production --hostname 0.0.0.0",
      env: {
        PORT: "3000",
        LOG_LEVEL: "info",
      },
    },
  ],
};
