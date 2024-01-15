#!/usr/bin/env bash
## The main script to setup a new Mac, with all the relevant configuration

# ------ Dependencies ------
source ./scripts/helpers/logging.sh
source ./scripts/helpers/checks.sh
source ./scripts/helpers/spinner.sh

# ------ Variable Initialization & Argument Parsing ------
PYTHON_VERSION_PREFIX=3.11

# usage <exit_code (0)>
usage() {
  readonly exit_code="${1:-0}"
  printf "\
Usage: ./setup.sh    [ -h | --help ]       Show this message
                     [ -v | --verbose ]    Show additional output
                     [ --tags ]            Specify which Ansible tags to run
                     [ --skip-tags ]       Specify which Ansible tags to skip
  "
  exit "$exit_code"
}

positional_args=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      ;;
    -v|--verbose)
      export FLAG_VERBOSE=1
      shift # past argument
      ;;
    --tags)
      arg_tags="$2"
      shift # past argument
      shift # past value
      ;;
    --skip-tags)
      arg_skip_tags="$2"
      shift # past argument
      shift # past value
      ;;
    -*|--*)
      error "Invalid option $1"
      usage 1
      ;;
    *)
      positional_args+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

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

  ## Install mise
  check "mise"
  if [[ $? -ne 0 ]]; then
    spin "mise not found, installing..." HOMEBREW_NO_AUTO_UPDATE=1 brew install mise
    eval "$(mise activate bash)"
  else
    success "mise already installed"
  fi

  ## Install Python
  checkCommand "mise ls --current python | grep ${PYTHON_VERSION_PREFIX}"
  if [[ $? -ne 0 ]]; then
    spin "Python ${PYTHON_VERSION_PREFIX} not found, installing..." mise use -g python@${PYTHON_VERSION_PREFIX}
  else
    success "Python ${PYTHON_VERSION_PREFIX} already installed"
  fi

  ## Install pipx
  check "pipx"
  if [[ $? -ne 0 ]]; then
    export PIPX_DEFAULT_PYTHON="$(mise which python)"
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
  [[ -z "$FLAG_VERBOSE" ]] || local flag_ansible_verbose="-vvv"
  [[ -z "$arg_tags" ]] || local flag_ansible_tags="--tags $arg_tags"
  [[ -z "$arg_skip_tags" ]] || local flag_ansible_skip_tags="--skip-tags $arg_skip_tags"
  info "Running Ansible..."
  ansible-playbook ./ansible/playbook.yml -K $flag_ansible_verbose $flag_ansible_tags $flag_ansible_skip_tags
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
