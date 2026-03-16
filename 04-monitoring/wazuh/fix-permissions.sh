#!/bin/bash
sudo chmod 500 config/wazuh_indexer_ssl_certs
sudo chmod 400 config/wazuh_indexer_ssl_certs/*
sudo chown -R 1000:1000 config/wazuh_indexer_ssl_certs
