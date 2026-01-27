/**
 * AST Chunker for TypeScript/JavaScript/GTS/GJS files
 * Bundled for JavaScriptCore execution from Swift
 * 
 * Usage from Swift:
 *   let result = context.evaluateScript("ASTChunker.parseAndChunk(source, 'typescript')")
 */

import { parse as babelParse } from '@babel/parser';

const MAX_CHUNK_LINES = 200;

/**
 * Main entry point - parse source and return chunks
 * @param {string} source - Source code to parse
 * @param {string} language - 'typescript' | 'javascript' | 'gts' | 'gjs'
 * @returns {string} JSON array of chunks
 */
function parseAndChunk(source, language) {
  try {
    const isGlimmer = language === 'gts' || language === 'gjs';
    const isTypeScript = language === 'typescript' || language === 'gts';
    
    // Preprocess GTS/GJS to extract <template> tags
    let processedSource = source;
    let templateRanges = [];
    
    if (isGlimmer) {
      const result = preprocessGlimmer(source);
      processedSource = result.processedSource;
      templateRanges = result.templateRanges;
    }
    
    // Parse with Babel
    const ast = babelParse(processedSource, {
      sourceType: 'module',
      plugins: [
        isTypeScript ? 'typescript' : null,
        'jsx',
        'decorators-legacy',
        'classProperties',
        'classPrivateProperties',
        'classPrivateMethods',
      ].filter(Boolean),
      errorRecovery: true,
    });
    
    // Extract chunks from AST
    const chunks = extractChunks(ast, source, templateRanges);
    
    return JSON.stringify(chunks);
  } catch (error) {
    // Return error info for debugging
    return JSON.stringify({
      error: true,
      message: error.message,
      stack: error.stack
    });
  }
}

/**
 * Preprocess GTS/GJS files to handle <template> tags
 * Replaces <template>...</template> with a placeholder that Babel can parse
 */
function preprocessGlimmer(source) {
  const templateRanges = [];
  
  // Find all <template> blocks and their positions
  const templateRegex = /<template\b[^>]*>([\s\S]*?)<\/template>/g;
  let match;
  while ((match = templateRegex.exec(source)) !== null) {
    const startLine = source.substring(0, match.index).split('\n').length;
    const endLine = source.substring(0, match.index + match[0].length).split('\n').length;
    templateRanges.push({ startLine, endLine, text: match[0], index: match.index, length: match[0].length });
  }
  
  // Replace <template> blocks with a placeholder that Babel can parse
  // We use a string literal assignment to preserve the structure
  let processedSource = source;
  let offset = 0;
  
  for (const range of templateRanges) {
    const placeholder = `__TEMPLATE_PLACEHOLDER__ = \`${range.text.replace(/`/g, '\\`').replace(/\$/g, '\\$')}\``;
    const adjustedIndex = range.index + offset;
    processedSource = 
      processedSource.substring(0, adjustedIndex) + 
      placeholder + 
      processedSource.substring(adjustedIndex + range.length);
    offset += placeholder.length - range.length;
  }
  
  return { processedSource, templateRanges };
}


/**
 * Extract chunks from Babel AST
 */
function extractChunks(ast, originalSource, templateRanges) {
  const lines = originalSource.split('\n');
  const chunks = [];
  
  // Collect top-level nodes
  const topLevelNodes = [];
  let importStart = null;
  let importEnd = null;
  
  for (const node of ast.program.body) {
    if (node.type === 'ImportDeclaration') {
      // Group imports together
      if (importStart === null) {
        importStart = node.loc.start.line;
      }
      importEnd = node.loc.end.line;
    } else {
      // If we were collecting imports, finalize that chunk
      if (importStart !== null) {
        topLevelNodes.push({
          type: 'imports',
          name: 'imports',
          startLine: importStart,
          endLine: importEnd
        });
        importStart = null;
        importEnd = null;
      }
      
      // Process this node
      const nodeInfo = extractNodeInfo(node, templateRanges);
      if (nodeInfo) {
        topLevelNodes.push(nodeInfo);
      }
    }
  }
  
  // Don't forget trailing imports
  if (importStart !== null) {
    topLevelNodes.push({
      type: 'imports',
      name: 'imports',
      startLine: importStart,
      endLine: importEnd
    });
  }
  
  // Convert to chunks with text
  for (const node of topLevelNodes) {
    const lineCount = node.endLine - node.startLine + 1;
    
    if (lineCount <= MAX_CHUNK_LINES) {
      // Single chunk
      chunks.push({
        startLine: node.startLine,
        endLine: node.endLine,
        text: extractLines(lines, node.startLine, node.endLine),
        constructType: mapConstructType(node.type),
        constructName: node.name,
        tokenCount: estimateTokens(lines, node.startLine, node.endLine)
      });
    } else {
      // Split large node (e.g., class with many methods)
      const subChunks = splitLargeNode(node, lines, templateRanges);
      chunks.push(...subChunks);
    }
  }
  
  return chunks;
}

/**
 * Extract info from a Babel AST node
 */
function extractNodeInfo(node, templateRanges) {
  const baseInfo = {
    startLine: node.loc.start.line,
    endLine: node.loc.end.line
  };
  
  switch (node.type) {
    case 'ClassDeclaration':
    case 'ClassExpression':
      // Check if this class contains a template (Glimmer component)
      const classEnd = expandForTemplates(baseInfo.endLine, templateRanges);
      return {
        type: 'class',
        name: node.id?.name || 'anonymous',
        startLine: baseInfo.startLine,
        endLine: classEnd
      };
      
    case 'FunctionDeclaration':
      return {
        type: 'function',
        name: node.id?.name || 'anonymous',
        ...baseInfo
      };
      
    case 'VariableDeclaration':
      // Check for arrow functions or class expressions
      const decl = node.declarations[0];
      if (decl?.init?.type === 'ArrowFunctionExpression' ||
          decl?.init?.type === 'FunctionExpression') {
        return {
          type: 'function',
          name: decl.id?.name || 'anonymous',
          ...baseInfo
        };
      }
      if (decl?.init?.type === 'ClassExpression') {
        return {
          type: 'class',
          name: decl.id?.name || 'anonymous',
          ...baseInfo
        };
      }
      // Skip simple variable declarations (too granular)
      return null;
      
    case 'ExportDefaultDeclaration':
    case 'ExportNamedDeclaration':
      // Recurse into the declaration
      if (node.declaration) {
        const inner = extractNodeInfo(node.declaration, templateRanges);
        if (inner) {
          return { ...inner, startLine: baseInfo.startLine };
        }
      }
      return null;
      
    case 'TSInterfaceDeclaration':
      return {
        type: 'interface',
        name: node.id?.name || 'anonymous',
        ...baseInfo
      };
      
    case 'TSTypeAliasDeclaration':
      return {
        type: 'type',
        name: node.id?.name || 'anonymous',
        ...baseInfo
      };
      
    case 'TSEnumDeclaration':
      return {
        type: 'enum',
        name: node.id?.name || 'anonymous',
        ...baseInfo
      };
      
    default:
      return null;
  }
}

/**
 * Expand end line to include any template tags that follow the class
 */
function expandForTemplates(endLine, templateRanges) {
  for (const range of templateRanges) {
    // If template starts right after class, include it
    if (range.startLine <= endLine + 2) {
      endLine = Math.max(endLine, range.endLine);
    }
  }
  return endLine;
}

/**
 * Split a large node into smaller chunks
 */
function splitLargeNode(node, lines, templateRanges) {
  const chunks = [];
  
  if (node.type === 'class') {
    // For classes, we could split by methods
    // For now, just create one large chunk (TODO: improve)
    chunks.push({
      startLine: node.startLine,
      endLine: node.endLine,
      text: extractLines(lines, node.startLine, node.endLine),
      constructType: mapConstructType('class'),
      constructName: node.name,
      tokenCount: estimateTokens(lines, node.startLine, node.endLine)
    });
  } else {
    // Default: single chunk
    chunks.push({
      startLine: node.startLine,
      endLine: node.endLine,
      text: extractLines(lines, node.startLine, node.endLine),
      constructType: mapConstructType(node.type),
      constructName: node.name,
      tokenCount: estimateTokens(lines, node.startLine, node.endLine)
    });
  }
  
  return chunks;
}

/**
 * Map internal type names to standard construct types
 */
function mapConstructType(type) {
  const mapping = {
    'class': 'classDecl',
    'function': 'function',
    'interface': 'protocolDecl',
    'type': 'protocolDecl',
    'enum': 'enumDecl',
    'imports': 'imports'
  };
  return mapping[type] || 'other';
}

/**
 * Extract lines from source (1-indexed)
 */
function extractLines(lines, startLine, endLine) {
  return lines.slice(startLine - 1, endLine).join('\n');
}

/**
 * Estimate token count (rough: ~4 chars per token)
 */
function estimateTokens(lines, startLine, endLine) {
  const text = lines.slice(startLine - 1, endLine).join('\n');
  return Math.ceil(text.length / 4);
}

// Export for JavaScriptCore
globalThis.ASTChunker = {
  parseAndChunk,
  version: '1.0.0'
};

export { parseAndChunk };
