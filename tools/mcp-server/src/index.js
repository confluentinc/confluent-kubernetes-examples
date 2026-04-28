#!/usr/bin/env node

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import CFKExamples from './cfk-examples.js';

const cfk = new CFKExamples();

const server = new Server(
  {
    name: 'cfk-examples-mcp',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Define available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'list_cfk_examples',
        description: 'List Confluent for Kubernetes (CFK) examples in a directory. Useful for browsing available examples.',
        inputSchema: {
          type: 'object',
          properties: {
            path: {
              type: 'string',
              description: 'Directory path within the CFK examples repository (empty for root)',
              default: ''
            }
          }
        }
      },
      {
        name: 'search_cfk_examples',
        description: 'Search for CFK examples by keyword. Searches across file names and content.',
        inputSchema: {
          type: 'object',
          properties: {
            query: {
              type: 'string',
              description: 'Search query (e.g., "kafka", "security", "tls", "rbac")'
            }
          },
          required: ['query']
        }
      },
      {
        name: 'get_cfk_example',
        description: 'Get the full content of a specific CFK example file or directory.',
        inputSchema: {
          type: 'object',
          properties: {
            path: {
              type: 'string',
              description: 'Path to the example file (e.g., "quickstart-deploy/confluent-platform.yaml")'
            }
          },
          required: ['path']
        }
      },
      {
        name: 'list_cfk_categories',
        description: 'List top-level categories of CFK examples (e.g., security, networking, blueprints).',
        inputSchema: {
          type: 'object',
          properties: {}
        }
      },
      {
        name: 'get_cfk_readme',
        description: 'Get the README for a specific CFK example directory.',
        inputSchema: {
          type: 'object',
          properties: {
            path: {
              type: 'string',
              description: 'Directory path (empty for root README)',
              default: ''
            }
          }
        }
      }
    ]
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  try {
    const { name, arguments: args } = request.params;

    switch (name) {
      case 'list_cfk_examples': {
        const examples = await cfk.listExamples(args.path || '');
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(examples, null, 2)
            }
          ]
        };
      }

      case 'search_cfk_examples': {
        if (!args.query) {
          throw new Error('Query parameter is required');
        }
        const results = await cfk.searchExamples(args.query);
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(results, null, 2)
            }
          ]
        };
      }

      case 'get_cfk_example': {
        if (!args.path) {
          throw new Error('Path parameter is required');
        }
        const content = await cfk.getExampleContent(args.path);
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(content, null, 2)
            }
          ]
        };
      }

      case 'list_cfk_categories': {
        const categories = await cfk.getTopLevelCategories();
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(categories, null, 2)
            }
          ]
        };
      }

      case 'get_cfk_readme': {
        const readme = await cfk.getREADME(args.path || '');
        if (readme) {
          return {
            content: [
              {
                type: 'text',
                text: readme.content
              }
            ]
          };
        } else {
          return {
            content: [
              {
                type: 'text',
                text: 'No README found for this path'
              }
            ]
          };
        }
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    return {
      content: [
        {
          type: 'text',
          text: `Error: ${error.message}`
        }
      ],
      isError: true
    };
  }
});

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error('CFK Examples MCP server running on stdio');
}

main().catch((error) => {
  console.error('Server error:', error);
  process.exit(1);
});
