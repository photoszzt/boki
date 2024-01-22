#!/bin/bash

ZK_ROOT=$HOME/apache-zookeeper-3.9.1-bin
export ZOO_LOG4J_PROP="WARN,CONSOLE"

${ZK_ROOT}/bin/zkCli.sh "$@"
