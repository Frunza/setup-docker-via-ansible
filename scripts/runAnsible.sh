#!/bin/sh

# Exit immediately if a simple command exits with a nonzero exit value
set -e

echo "Running Ansible playbooks..."
ansible-playbook -i ansible/inventory.ini ansible/nodes.yml
