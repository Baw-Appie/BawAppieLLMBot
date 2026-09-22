#!/bin/bash

swift build -c release \
  --swift-sdk aarch64-swift-linux-musl \
  --product BawAppieLLMBot \
  -Xlinker --strip-all
