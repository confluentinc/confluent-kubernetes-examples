import fetch from 'node-fetch';

const CFK_REPO = 'confluentinc/confluent-kubernetes-examples';
const GITHUB_API = 'https://api.github.com';
const RAW_GITHUB = 'https://raw.githubusercontent.com';

class CFKExamples {
  constructor(githubToken = null) {
    this.githubToken = githubToken || process.env.GITHUB_TOKEN;
    this.headers = {
      'Accept': 'application/vnd.github.v3+json',
      'User-Agent': 'CFK-Examples-MCP'
    };
    if (this.githubToken) {
      this.headers['Authorization'] = `token ${this.githubToken}`;
    }
  }

  async listExamples(path = '') {
    try {
      const url = `${GITHUB_API}/repos/${CFK_REPO}/contents/${path}`;
      const response = await fetch(url, { headers: this.headers });

      if (!response.ok) {
        throw new Error(`GitHub API error: ${response.status} ${response.statusText}`);
      }

      const contents = await response.json();

      // Filter for directories and YAML/MD files
      const examples = contents
        .filter(item => item.type === 'dir' || item.name.match(/\.(yaml|yml|md)$/i))
        .map(item => ({
          name: item.name,
          path: item.path,
          type: item.type,
          url: item.html_url,
          download_url: item.download_url
        }));

      return examples;
    } catch (error) {
      throw new Error(`Failed to list examples: ${error.message}`);
    }
  }

  async searchExamples(query) {
    try {
      const url = `${GITHUB_API}/search/code?q=${encodeURIComponent(query)}+repo:${CFK_REPO}`;
      const response = await fetch(url, { headers: this.headers });

      if (!response.ok) {
        throw new Error(`GitHub API error: ${response.status} ${response.statusText}`);
      }

      const data = await response.json();

      return data.items.map(item => ({
        name: item.name,
        path: item.path,
        url: item.html_url,
        repository: item.repository.full_name,
        score: item.score
      }));
    } catch (error) {
      throw new Error(`Failed to search examples: ${error.message}`);
    }
  }

  async getExampleContent(path) {
    try {
      // Try to get from GitHub API first (for metadata)
      const apiUrl = `${GITHUB_API}/repos/${CFK_REPO}/contents/${path}`;
      const apiResponse = await fetch(apiUrl, { headers: this.headers });

      if (!apiResponse.ok) {
        throw new Error(`GitHub API error: ${apiResponse.status} ${apiResponse.statusText}`);
      }

      const metadata = await apiResponse.json();

      // Get raw content
      if (metadata.download_url) {
        const contentResponse = await fetch(metadata.download_url);
        const content = await contentResponse.text();

        return {
          name: metadata.name,
          path: metadata.path,
          content: content,
          size: metadata.size,
          url: metadata.html_url,
          type: metadata.type
        };
      } else if (metadata.type === 'dir') {
        // If it's a directory, return the list of files
        return {
          name: metadata.name,
          path: metadata.path,
          type: 'directory',
          url: metadata.html_url,
          files: await this.listExamples(path)
        };
      }
    } catch (error) {
      throw new Error(`Failed to get example content: ${error.message}`);
    }
  }

  async getTopLevelCategories() {
    try {
      const examples = await this.listExamples('');
      const categories = examples
        .filter(item => item.type === 'dir')
        .map(item => ({
          name: item.name,
          path: item.path,
          description: this.getCategoryDescription(item.name)
        }));

      return categories;
    } catch (error) {
      throw new Error(`Failed to get categories: ${error.message}`);
    }
  }

  getCategoryDescription(categoryName) {
    const descriptions = {
      'quickstart-deploy': 'Quick start deployment examples for CFK',
      'security': 'Security configuration examples (TLS, RBAC, etc.)',
      'hybrid': 'Hybrid cloud deployment examples',
      'blueprints': 'Production-ready blueprints and reference architectures',
      'networking': 'Networking configuration examples',
      'monitoring': 'Monitoring and observability examples',
      'disaster-recovery': 'Disaster recovery and backup examples'
    };

    return descriptions[categoryName] || 'CFK configuration examples';
  }

  async getREADME(path = '') {
    try {
      const readmePath = path ? `${path}/README.md` : 'README.md';
      const content = await this.getExampleContent(readmePath);
      return content;
    } catch (error) {
      return null;
    }
  }
}

export default CFKExamples;
