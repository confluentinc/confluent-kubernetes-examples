#!/usr/bin/env node

import { program } from 'commander';
import CFKExamples from './cfk-examples.js';

const cfk = new CFKExamples();

program
  .name('cfk-examples')
  .description('CLI to access Confluent for Kubernetes (CFK) examples')
  .version('1.0.0');

program
  .command('list [path]')
  .description('List CFK examples in a directory')
  .action(async (path = '') => {
    try {
      const examples = await cfk.listExamples(path);
      console.log(JSON.stringify(examples, null, 2));
    } catch (error) {
      console.error('Error:', error.message);
      process.exit(1);
    }
  });

program
  .command('search <query>')
  .description('Search for CFK examples')
  .action(async (query) => {
    try {
      const results = await cfk.searchExamples(query);
      console.log(JSON.stringify(results, null, 2));
    } catch (error) {
      console.error('Error:', error.message);
      process.exit(1);
    }
  });

program
  .command('get <path>')
  .description('Get content of a specific example')
  .option('-r, --raw', 'Output raw content only')
  .action(async (path, options) => {
    try {
      const content = await cfk.getExampleContent(path);
      if (options.raw && content.content) {
        console.log(content.content);
      } else {
        console.log(JSON.stringify(content, null, 2));
      }
    } catch (error) {
      console.error('Error:', error.message);
      process.exit(1);
    }
  });

program
  .command('categories')
  .description('List top-level categories of CFK examples')
  .action(async () => {
    try {
      const categories = await cfk.getTopLevelCategories();
      console.log(JSON.stringify(categories, null, 2));
    } catch (error) {
      console.error('Error:', error.message);
      process.exit(1);
    }
  });

program
  .command('readme [path]')
  .description('Get README for a specific example directory')
  .action(async (path = '') => {
    try {
      const readme = await cfk.getREADME(path);
      if (readme) {
        console.log(readme.content);
      } else {
        console.log('No README found');
      }
    } catch (error) {
      console.error('Error:', error.message);
      process.exit(1);
    }
  });

program.parse();
