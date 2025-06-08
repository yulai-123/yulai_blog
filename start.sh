#!/bin/bash

git pull;

ps -ef | grep hexo | grep -v grep | awk '{print $2}' | xargs kill -9;

hexo clean
hexo generate
nohup hexo server -p 4567 -s > logs/hexo.log 2>&1 &