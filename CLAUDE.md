# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an **n8n workflow project** for tech journaling. n8n workflows are stored as JSON files and can be imported/exported via the n8n UI or CLI.

## n8n Workflow Development

Workflows are defined as JSON files. When working with n8n workflows in this repo:

- Use the `n8n-mcp-skills` skills for node configuration, expression syntax, and workflow patterns
- Workflow JSON files can be imported into n8n via **Settings → Import from file**
- Expressions use `{{ }}` syntax with variables like `$json`, `$node`, `$input`
- JavaScript Code nodes use `$input.all()`, `$input.first()`, `$json` etc.
- Always create json files on project files sytsem just before send to n8n using mcp. Json files should be the same like this one send to n8n. When you change sth in json file always reflect changes in local file just before send to n8n using mcp.

## Relevant Skills

When working on this project, prefer these skills:
- `n8n-mcp-skills:n8n-workflow-patterns` — architectural patterns for workflows
- `n8n-mcp-skills:n8n-node-configuration` — configuring individual nodes
- `n8n-mcp-skills:n8n-code-javascript` — writing JS in Code nodes
- `n8n-mcp-skills:n8n-expression-syntax` — writing and validating expressions
