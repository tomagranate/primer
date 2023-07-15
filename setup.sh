#!/usr/bin/env bash
## The main script to setup a new Mac, with all the relevant configuration

# ------ Variable Initialization & Argument Parsing ------
VERBOSE=0
PYTHON_VERSION_PREFIX=3.11

usage() {
  printf "\
Usage: ./setup.sh    [ -h | --help ]       Show this message
                     [ -v | --verbose ]    Show additional output
  "
  exit 2
}

while getopts ":hv-:" opt; do
  case "$opt" in
    -)
      case "${OPTARG}" in
        help)
          usage
          ;;
        verbose)
          VERBOSE=1
          ;;
        *)
          usage
          ;;
      esac
      ;;
    h)
      usage
      ;;
    v)
      VERBOSE=1
      ;;
    *)
      usage
      ;;
  esac
done

# ------ Dependencies ------
source ./scripts/helpers/logging.sh
source ./scripts/helpers/checks.sh
source ./scripts/helpers/spinner.sh

# ------ Core Logic ------
setup() {
  ## Install Homebrew
  check "brew"
  if [[ $? -ne 0 ]]; then
    spin "Homebrew not found, installing..." /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    success "Homebrew already installed"
  fi

  ## Install rtx
  check "rtx"
  if [[ $? -ne 0 ]]; then
    spin "rtx not found, installing..." HOMEBREW_NO_AUTO_UPDATE=1 brew install rtx
    eval "$(rtx activate bash)"
  else
    success "rtx already installed"
  fi

  ## Install Python
  checkCommand "rtx ls --current python | grep ${PYTHON_VERSION_PREFIX}"
  if [[ $? -ne 0 ]]; then
    spin "Python ${PYTHON_VERSION_PREFIX} not found, installing..." rtx use -g python@${PYTHON_VERSION_PREFIX}
  else
    success "Python ${PYTHON_VERSION_PREFIX} already installed"
  fi

  ## Install pipx
  check "pipx"
  if [[ $? -ne 0 ]]; then
    export PIPX_DEFAULT_PYTHON="$(rtx which python)"
    spin "pipx not found, installing..." HOMEBREW_NO_AUTO_UPDATE=1 brew install pipx
    export PATH=$PATH:~/.local/bin
  else
    success "pipx already installed"
  fi

  ## Install Ansible
  check "ansible-playbook"
  if [[ $? -ne 0 ]]; then
    spin "Ansible not found, installing..." pipx install --force --include-deps ansible
  else
    success "Ansible already installed"
  fi

  ## Install Ansible Galaxy roles and collections
  spin "Installing Ansible Galaxy roles and collections..." ansible-galaxy install -r ./ansible/requirements.yml
}

ansible() {
  ANSIBLE_VERBOSE_FLAG=""
  if [[ "$VERBOSE" -ne 0 ]]; then
    ANSIBLE_VERBOSE_FLAG="-vvv"
  fi
  info "Running Ansible..."
  ansible-playbook ./ansible/playbook.yml -K $ANSIBLE_VERBOSE_FLAG
  if [[ $? -ne 0 ]]; then
    error "Ansible failed, please review any errors above."
    exit 1
  fi
  success "Ansible completed successfully"
}

# ------ Main ------
setup
ansible
success "Setup completed successfully"
