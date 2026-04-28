# CFK Examples MCP Server

MCP server and CLI for accessing Confluent for Kubernetes (CFK) examples from the [confluent-kubernetes-examples](https://github.com/confluentinc/confluent-kubernetes-examples) repository.

## Features

- **Browse**: List examples by category and directory
- **Search**: Find examples by keyword across files and content
- **Retrieve**: Get full content of example YAML files and documentation
- **Categories**: Explore organized example categories (security, networking, blueprints, etc.)

## Installation

### Option 1: NPM Install (Recommended)

```bash
npm install -g cfk-examples-mcp
```

### Option 2: Local Development

```bash
git clone <this-repo>
cd cfk-examples-mcp
npm install
npm link  # Makes CLI globally available
```

## Usage

### As a CLI

```bash
# List top-level categories
cfk-examples categories

# List examples in a directory
cfk-examples list quickstart-deploy

# Search for examples
cfk-examples search "kafka tls"

# Get a specific example
cfk-examples get quickstart-deploy/confluent-platform.yaml

# Get a README
cfk-examples readme quickstart-deploy
```

### As an MCP Server with Claude Code

#### Add the MCP Server

```bash
claude mcp add cfk-examples node /path/to/cfk-examples-mcp/src/index.js
```

Or if installed globally via npm:

```bash
claude mcp add cfk-examples npx -y cfk-examples-mcp
```

#### Verify Installation

```bash
claude mcp list
```

You should see `cfk-examples` in the list.

#### Use in Claude Code

Start a Claude Code session and ask questions like:

- "List all CFK example categories"
- "Show me security examples for CFK"
- "Get the confluent-platform quickstart example"
- "Search for TLS configuration examples"
- "Show me the README for the blueprints directory"

## Available MCP Tools

When connected as an MCP server, the following tools are available:

1. **list_cfk_examples** - List examples in a directory
2. **search_cfk_examples** - Search for examples by keyword
3. **get_cfk_example** - Get full content of an example file
4. **list_cfk_categories** - List top-level example categories
5. **get_cfk_readme** - Get README for a directory

## Authentication

The tool uses the GitHub API to fetch examples. For better rate limits:

```bash
export GITHUB_TOKEN=your_github_token
```

Get a token from [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens). No special scopes needed for public repositories.

## Examples

### CLI Examples

```bash
# See all categories
cfk-examples categories

# Browse security examples
cfk-examples list security

# Search for RBAC examples
cfk-examples search rbac

# Get a specific YAML file
cfk-examples get security/production-secure-deploy/confluent-platform-mtls-rbac.yaml --raw

# Read the quickstart README
cfk-examples readme quickstart-deploy
```

### Claude Code Examples

Once the MCP server is running, you can ask Claude:

```
Show me all the categories of CFK examples available
```

```
Get the quickstart deployment example for confluent-platform
```

```
Search for examples related to TLS and mTLS configuration
```

```
What's in the security/production-secure-deploy directory?
```

## Project Structure

```
cfk-examples-mcp/
├── src/
│   ├── index.js          # MCP server implementation
│   ├── cli.js            # CLI interface
│   └── cfk-examples.js   # Core logic for fetching examples
├── package.json
└── README.md
```

## Development

```bash
# Run MCP server directly
node src/index.js

# Test CLI
node src/cli.js list
node src/cli.js search kafka

# Test as MCP with Claude Code
claude mcp add cfk-examples-dev node $(pwd)/src/index.js
```

## Troubleshooting

### "API rate limit exceeded"

Set a GitHub token:
```bash
export GITHUB_TOKEN=your_token
```

### "Module not found"

Make sure dependencies are installed:
```bash
npm install
```

### MCP server not showing in Claude Code

1. Check the server is added: `claude mcp list`
2. Remove and re-add: `claude mcp remove cfk-examples && claude mcp add ...`
3. Restart Claude Code session

## License

Apache 2.0 (same as Confluent projects)
