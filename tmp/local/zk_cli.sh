#!/bin/bash

ZK_ROOT=/home/ubuntu/Downloads/apache-zookeeper-3.6.2-bin
export ZOO_LOG4J_PROP="WARN,CONSOLE"

${ZK_ROOT}/bin/zkCli.sh "$@"
