# sports_mech_automation

Automated file-deployment tooling plus a sample multi-folder web app for testing it.

## Layout

```
sports_mech_automation/
├── deploy.sh        # interactive deployment script (clone repo -> backup -> copy into web root)
├── webapp/          # sample multi-folder app (served from a web server's document root)
│   ├── index.html
│   ├── assets/      # css, js (pages/registration, pages/dashboard, vendor), images
│   ├── application/ # controllers, models, views (redesign, layouts), config, libraries, helpers
│   ├── api/v1/      # status.json
│   ├── uploads/     # runtime (gitignored)
│   └── logs/        # runtime (gitignored)
└── .gitignore
```

## deploy.sh

Interactive deployment of selected repo files into a web root. Prompts for
environment type/level, git repo URL, branch, source subdir, destination
folder, and the list of files. Backs up existing files before overwriting,
then prints a summary.

### Usage

```bash
# safe preview — changes nothing
./deploy.sh --dry-run --base /tmp/test-webroot

# test against a real local web root
sudo ./deploy.sh --base /var/www/html

# real run on the server (default base /var/www/html)
sudo ./deploy.sh
```

Options:
- `--dry-run`         preview every action without changing anything
- `--base <path>`     override the web-root base (default `/var/www/html`)
- `--yes`, `-y`       skip the live-deployment confirmation prompt

## Local test setup

The `webapp/` project is served by Apache at `http://localhost/myapp/`
(document root `/var/www/html/myapp`). Edit files here, push to Git, then use
`deploy.sh` to promote selected files into the served document root.
# automation_file_update
