#!/bin/bash

set -e

# shellcheck disable=1004
echo '
Welcome! This script will guide you through the process of setting up a
Canvas development environment with docker.'

OS="$(uname)"

function installed {
  type "$@" &> /dev/null
}

install='sudo apt-get update && sudo apt-get install -y'
dependencies='docker-compose'

function message {
  echo ''
}

function prompt {
  read -r -p "$1 " "$2"
}

function install_dependencies {
  local packages=()
  for package in $dependencies; do
    installed "$package" || packages+=("$package")
  done
  [[ ${#packages[@]} -gt 0 ]] || return 0

  message "First, we need to install some dependencies."
  if [[ $OS == 'Linux' ]] && ! installed apt-get; then
    echo 'This script only supports Debian-based Linux (for now - contributions welcome!)'
    exit 1
  fi
  confirm_command "$install ${packages[*]}"
}

function start_docker_daemon {
  service docker status &> /dev/null && return 0
  sudo service docker start
  sleep 1 # wait for docker daemon to start
}

function install_dory {
  installed dory && return 0
  message 'Installing dory...'

  if ! installed gem; then
    message "You need ruby to run dory (it's a gem). Install ruby and try again."
    return 1
  fi

  prompt "Use sudo to install dory gem? You may need this if using system ruby [y/n]" use_sudo
  if [[ ${use_sudo:-n} == 'y' ]]; then
    eval "sudo gem install dory"
  else
    eval "gem install dory"
  fi
}

function start_dory {
  message 'Starting dory...'
  if dory status | grep -q 'not running'; then
    eval "dory up"
  else
    message 'Looks like dory is already running. Moving on...'
  fi
}

function setup_docker_as_nonroot {
  docker ps &> /dev/null && return 0
  message 'Setting up docker for nonroot user...'

  if ! id -Gn "$USER" | grep -q '\bdocker\b'; then
    message "Adding $USER user to docker group..."
    eval "sudo usermod -aG docker $USER" || true
  fi

  message 'We need to login again to apply that change.'
  eval "exec sg docker -c $0"
}

function setup_docker_environment {
  install_dependencies
  if [[ $OS == 'Linux' ]]; then
    message "It looks like you're using Linux. You'll need dory. Let's set that up."
    start_docker_daemon
    setup_docker_as_nonroot
    install_dory
    start_dory
  fi
  if [ -f "docker-compose.override.yml" ]; then
    message "docker-compose.override.yml exists, skipping copy of default configuration"
  else
    message "Copying default configuration from config/docker-compose.override.yml.example to docker-compose.override.yml"
    cp config/docker-compose.override.yml.example docker-compose.override.yml
  fi
}

function copy_docker_config {
  message 'Copying Canvas docker configuration...'
  eval 'cp docker-compose/config/* config/' || true
}

function build_images {
  message 'Building docker images...'
  docker-compose build --pull
}

function check_gemfile {
  if [[ -e Gemfile.lock ]]; then
    message \
'For historical reasons, the Canvas Gemfile.lock is not tracked by git. We may
need to remove it before we can install gems, to prevent conflicting depencency
errors.'
    eval 'rm Gemfile.lock' || true
  fi

  # Fixes 'error while trying to write to `/usr/src/app/Gemfile.lock`'
  if ! docker-compose run --no-deps --rm web touch Gemfile.lock; then
    message \
"The 'docker' user is not allowed to write to Gemfile.lock. We need write
permissions so we can install gems."
    touch Gemfile.lock
    eval 'chmod a+rw Gemfile.lock' || true
  fi
}

function database_exists {
  docker-compose run --rm web \
    bundle exec rails runner 'ActiveRecord::Base.connection' &> /dev/null
}

function create_db {
  if ! docker-compose run --no-deps --rm web touch db/structure.sql; then
    message \
"The 'docker' user is not allowed to write to db/structure.sql. We need write
permissions so we can run migrations."
    touch db/structure.sql
    eval 'chmod a+rw db/structure.sql' || true
  fi

  if database_exists; then
    message \
'An existing database was found.

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
This script will destroy ALL EXISTING DATA if it continues
If you want to migrate the existing database, use docker_dev_update.sh
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    message 'About to run "bundle exec rake db:drop"'
    prompt "type NUKE in all caps: " nuked
    [[ ${nuked:-n} == 'NUKE' ]] || exit 1
    docker-compose run --rm web bundle exec rake db:drop
  fi

  message "Creating new database"
  docker-compose run --rm web \
    bundle exec rake db:create
  docker-compose run --rm web \
    bundle exec rake db:migrate
  docker-compose run --rm web \
    bundle exec rake db:initial_setup
}

function setup_canvas {
  message 'Now we can set up Canvas!'
  copy_docker_config
  build_images

  check_gemfile
  docker-compose run --rm web ./script/canvas_update -n code -n data
  create_db
  docker-compose run --rm web ./script/canvas_update -n code -n deps
}

function display_next_steps {
  message "You're good to go! Next steps:"

  [[ $OS == 'Linux' ]] && echo '
  I have added your user to the docker group so you can run docker commands
  without sudo. Note that this has security implications:

  https://docs.docker.com/engine/installation/linux/linux-postinstall/

  You may need to logout and login again for this to take effect.'

  echo "
  Running Canvas:

    docker-compose up -d
    open http://canvas.docker

  Running the tests:

    docker-compose run --rm web bundle exec rspec

  I'm stuck. Where can I go for help?

    FAQ:           https://github.com/instructure/canvas-lms/wiki/FAQ
    Dev & Friends: http://instructure.github.io/
    Canvas Guides: https://guides.instructure.com/
    Vimeo channel: https://vimeo.com/canvaslms
    API docs:      https://canvas.instructure.com/doc/api/index.html
    Mailing list:  http://groups.google.com/group/canvas-lms-users
    IRC:           http://webchat.freenode.net/?channels=canvas-lms

    Please do not open a GitHub issue until you have tried asking for help on
    the mailing list or IRC - GitHub issues are for verified bugs only.
    Thanks and good luck!
  "
}

#setup_docker_environment
setup_canvas
display_next_steps
