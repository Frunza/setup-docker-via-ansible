# Setup Docker via Ansible

## Goal

Set up `Docker` via `Ansible` in a virtual machine.

Note: `Ansible` needs SSH access to the target machine. You can find out how to configure SSH access in the docker container at [https://github.com/Frunza/configure-docker-container-with-ssh-access](https://github.com/Frunza/configure-docker-container-with-ssh-access)

## Prerequisites

A Linux or MacOS machine for local development. If you are running Windows, you first need to set up the *Windows Subsystem for Linux (WSL)* environment.

You need `docker cli` on your machine for testing purposes, and/or on the machines that run your pipeline.
You can check this by running the following command:
```sh
docker --version
```

A few virtual machines that you can use to set up `Docker`. Make sure that you already have a `Docker` container with SSH access to all of the virtual machines.

## Containerization preparation

Let's prepare the setup to run everything in containers. First, let's create a `Dockerfile` where we set up `Ansible`:
```sh
# Dockerfile
FROM alpine:3.18.0

ARG SSH_PRIVATE_KEY
RUN mkdir -p /root/.ssh
RUN echo "$SSH_PRIVATE_KEY" | tr -d '\r' > /root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa

RUN apk --no-cache add ansible=7.5.0-r0

COPY ./scripts /app
COPY ./ansible /app/ansible
```
Here we first add an SSH key via a build argument, which we provide as an environment variable. We then create the directory and copy the content of the argument into a file at the correct location. The next step is to install `Ansible`, which we do by using a fixed version. At the end we copy our own stuff.

Now we can create a `Docker` compose file with a service that runs `Ansible`:
```sh
services:
  main:
    image: ansibledocker
    network_mode: host
    working_dir: /app
    environment:
      # location of ansible config: https://docs.ansible.com/ansible/latest/reference_appendices/config.html#ansible-configuration-settings-locations
      - ANSIBLE_CONFIG=/app/ansible/ansible.cfg
    entrypoint: ["sh", "-c"]
    command: ["sh runAnsible.sh"]
```
The service is called *main*, and it runs a script for `Ansible`. We also have an environment variables with the SSH key needed to connect to the virtual machines, used by `Ansible`.

In the *runAnsible.sh* script we just want to do call our `Ansible` playbook like:
```sh
#!/bin/sh

# Exit immediately if a simple command exits with a nonzero exit value
set -e

echo "Running Ansible playbooks..."
ansible-playbook -i ansible/inventory.ini ansible/nodes.yml
```

This is the boilerplate to run everything in containers. Now we can focus on setting up `Docker` via `Ansible`.

## Implementation

Let's first create some basic `Ansible` configuration:
```sh
# ansible/ansible.cfg
[defaults]
host_key_checking = False
remote_user = ubuntu
interpreter_python = auto_silent

[privilege_escalation]
become = True
become_method = sudo
become_user = root
```
Depending on your virtual machine, you might want to set the *remote_user* to root also, if you so desire.
The inventory file can look like:
```sh
# ansible/inventory.ini
[servers]
192.168.2.1
192.168.2.2
```
Don't forget to update the hosts with your target virtual machines.

First of all, let's find out what `Docker` version we can use. If you are using `Ubuntu` virtual machines, you can call:
```sh
apt list -a docker-ce
```
inside a virtual machine, which will return something like:
```sh
Listing... Done
docker-ce/jammy 5:29.4.1-1~ubuntu.22.04~jammy amd64
docker-ce/jammy 5:29.4.0-1~ubuntu.22.04~jammy amd64
docker-ce/jammy 5:29.3.1-1~ubuntu.22.04~jammy amd64
...
```
If you want to use the currently latest version, you must remember take the whole string, like: *5:29.4.1-1~ubuntu.22.04~jammy*.

The playbook to set up `Docker` looks like:
```sh
# ansible/nodes.yml
- name: Setup Docker
  hosts:
    - servers
  gather_facts: true
  become: true
  vars:
    dockerVersion: "5:29.4.0-1~ubuntu.22.04~jammy"

  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install required packages
      apt:
        name:
          - ca-certificates
          - curl
          - gnupg
        state: present

    - name: Create keyrings directory
      file:
        path: /etc/apt/keyrings
        state: directory
        mode: '0755'

    - name: Add Docker GPG key
      get_url:
        url: https://download.docker.com/linux/ubuntu/gpg
        dest: /etc/apt/keyrings/docker.asc
        mode: '0644'
    - name: Add Docker repository
      apt_repository:
        repo: "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
        state: present
      register: dockerRepo

    - name: Update apt cache after adding Docker repo
      apt:
        update_cache: yes
      when: dockerRepo.changed

    - name: Remove hold from Docker packages
      dpkg_selections:
        name: "{{ item }}"
        selection: install
      loop:
        - docker-ce
        - docker-ce-cli
        - containerd.io
        - docker-compose-plugin

    - name: Install specific Docker version
      apt:
        name:
          - "docker-ce={{ dockerVersion }}"
          - "docker-ce-cli={{ dockerVersion }}"
          - containerd.io
          - docker-compose-plugin
        state: present
        allow_downgrade: yes

    - name: Hold Docker packages
      dpkg_selections:
        name: "{{ item }}"
        selection: hold
      loop:
        - docker-ce
        - docker-ce-cli
        - containerd.io
        - docker-compose-plugin

    - name: Ensure Docker service is enabled and running
      systemd:
        name: docker
        enabled: yes
        state: started
```
Note that we are using a variable with the `Docker` version found before.
The first task just updates the `apt` cache if it is older than one hour.
The second task installs a list of packages: `curl` is a nice to have utility; `ca-certificates` is required by `Docker` and you can find more about `Docker` installation at *https://docs.docker.com/engine/install/ubuntu/*; `gnupg` will be needed later to verify the `Docker` GPG key signature and manage `apt`'s keyring system.
The third task creates a keyrings directory and the fourth task a `Docker` GPG key into it.
The fifth task adds the `Docker` repository to `apt`, and the next task updates the `apt` cache again if the `Docker` repository was added or changed.
The next 3 tasks install `Docker` and make sure that it cannot be updated unintentionally. The way to do this is to tell `Ubuntu` to hold the `Docker` packages after its installation and remove the hold right before the installation. The `Docker` installation tasks is using the variable we defined at the beginning of the playbook.
The last task ensures that `Docker` is running and starts after machine restart.

To change the `Docker` version, you can just find another version and run the playbook again. For example, you can even downgrade `Docker` by updating the version to *5:24.0.7-1~ubuntu.22.04~jammy* and running the playbook.

## Considerations

`containerd.io` and `docker-compose-plugin` are not version pinned, which could cause problems if you downgrade to older `Docker` versions. I left these out because it is unlikely to cause issues in most environments because of these, but feel free to pin these as well.
