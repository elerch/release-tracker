# Release Tracker

A Zig application that monitors releases from starred repositories across GitHub, GitLab, Codeberg, and SourceHut, generating an RSS feed for easy consumption. Note that this application was primarily AI generated

## Features

- Monitor releases from multiple Git hosting platforms
- Generate RSS feed of new releases
- Configurable authentication for each platform
- Designed to run periodically as a CLI tool
- Static file output suitable for deployment on Cloudflare Pages

## Building

Requires Zig 0.14.1:

```bash
zig build
```

## Usage

1. Copy `config.example.json` to `config.json` and fill in your API tokens
2. Run the application:

```bash
./zig-out/bin/release-tracker config.json
```

3. The RSS feed will be generated as `releases.xml`

## Configuration

Create a `config.json` file with your API tokens:

```json
{
  "github_token": "your_github_token",
  "gitlab_token": "your_gitlab_token", 
  "codeberg_token": "your_codeberg_token",
  "sourcehut": {
    "repositories": [
      "~sircmpwn/aerc",
      "~emersion/gamja"
    ]
  },
  "last_check": null
}
```

### API Token Setup

- **GitHub**: Create a Personal Access Token with `public_repo` and `user` scopes
- **GitLab**: Create a Personal Access Token with `read_api` scope
- **Codeberg**: Create an Access Token in your account settings
- **SourceHut**: No token required for public repositories. Specify repositories to track in the configuration.

## Testing

Run the test suite:

```bash
zig build test
```

Run integration tests:

```bash
zig build test -Dintegration=true
```

Enable debug output in tests (useful for debugging test failures):

```bash
zig build test -Dintegration=true -Dtest-debug=true
```

Test individual providers:

```bash
zig build test-github
zig build test-gitlab
zig build test-codeberg
zig build test-sourcehut
```

## Deployment

This tool is designed to be run periodically (e.g., via cron) and commit the generated RSS file to a Git repository that can be deployed via Cloudflare Pages or similar static hosting services.

Example cron job (runs every hour):
```bash
0 * * * * cd /path/to/release-tracker && ./zig-out/bin/release-tracker config.json && git add releases.xml && git commit -m "Update releases" && git push
```
