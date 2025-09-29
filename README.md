`gitx` provides scripts to help you install or uninstall custom git extensions for your local environment.

## How the Scripts Work

- **install.sh**: This script sets up the gitx extensions on your system. It may copy executable files, set up aliases, or add scripts to a directory in your `$PATH` so you can use the new gitx commands globally.
- **uninstall.sh**: This script removes the gitx extensions and undoes any changes made by the installation script, ensuring your system is clean if you want to remove gitx.

Both scripts are written to run safely with minimal user interaction.

## How to Pull and Use the Scripts

To install gitx, run:

```sh
curl -fsSL https://raw.githubusercontent.com/brimdor/gitx/main/install.sh | bash
```

To uninstall gitx, run:

```sh
curl -fsSL https://raw.githubusercontent.com/brimdor/gitx/main/uninstall.sh | bash
```

- `curl -fsSL <url>` fetches the script securely from the repository.
- The output is piped directly to `bash`, which executes the script.
- Always review scripts before running them from the internet, or inspect the repository to understand what the installation and uninstallation will do.

## Usage

After installation, you can start using the gitx extensions as described in this repository. See individual script documentation for specific commands and options.
