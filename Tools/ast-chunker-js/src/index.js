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
    
    // Extract file-level metadata (imports, etc.)
    const fileMetadata = extractFileMetadata(ast, isGlimmer);
    
    // Extract chunks from AST
    const chunks = extractChunks(ast, source, templateRanges, fileMetadata);
    
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
 * Extract file-level metadata from AST
 */
function extractFileMetadata(ast, isGlimmer) {
  const imports = [];
  const tioUiImports = [];
  let usesEmberConcurrency = false;
  const frameworks = [];
  
  for (const node of ast.program.body) {
    if (node.type === 'ImportDeclaration') {
      const source = node.source.value;
      imports.push(source);
      
      // Detect ember-concurrency
      if (source === 'ember-concurrency') {
        usesEmberConcurrency = true;
      }
      
      // Detect TIO-UI imports
      if (source.startsWith('tio-ui/') || source === 'tio-ui') {
        // Extract specific components imported
        for (const specifier of node.specifiers) {
          if (specifier.type === 'ImportSpecifier' && specifier.imported) {
            tioUiImports.push(specifier.imported.name);
          }
        }
      }
      
      // Detect frameworks from imports
      if (source.startsWith('@glimmer/') || source.startsWith('@ember/')) {
        if (!frameworks.includes('Ember')) frameworks.push('Ember');
      }
      if (source.startsWith('react')) {
        if (!frameworks.includes('React')) frameworks.push('React');
      }
      if (source.startsWith('vue')) {
        if (!frameworks.includes('Vue')) frameworks.push('Vue');
      }
    }
  }
  
  if (isGlimmer && !frameworks.includes('Ember')) {
    frameworks.push('Ember');
  }
  
  return { imports, tioUiImports, usesEmberConcurrency, frameworks };
}

/**
 * Preprocess GTS/GJS files to handle <template> tags
 * Uses depth-tracking instead of lazy regex to handle nested HTML <template> elements
 */
function preprocessGlimmer(source) {
  const templateRanges = [];
  
  // Find top-level <template> blocks using depth tracking.
  // The content-tag spec uses <template> at module/class scope.
  // Inner HTML <template> elements may appear in the content.
  let searchFrom = 0;
  const openTag = /<template\b[^>]*>/g;
  const closeTag = /<\/template>/g;
  
  while (searchFrom < source.length) {
    // Find next opening <template>
    openTag.lastIndex = searchFrom;
    const openMatch = openTag.exec(source);
    if (!openMatch) break;
    
    const blockStart = openMatch.index;
    const contentStart = blockStart + openMatch[0].length;
    let depth = 1;
    let pos = contentStart;
    
    // Track depth to find the matching closing tag
    while (depth > 0 && pos < source.length) {
      // Find next opening or closing tag from current position
      openTag.lastIndex = pos;
      closeTag.lastIndex = pos;
      
      const nextOpen = openTag.exec(source);
      const nextClose = closeTag.exec(source);
      
      if (!nextClose) {
        // No closing tag found — malformed, bail out
        break;
      }
      
      if (nextOpen && nextOpen.index < nextClose.index) {
        // Opening tag comes first — increase depth
        depth++;
        pos = nextOpen.index + nextOpen[0].length;
      } else {
        // Closing tag comes first — decrease depth
        depth--;
        if (depth === 0) {
          // Found the matching close for our top-level <template>
          const blockEnd = nextClose.index + nextClose[0].length;
          const fullText = source.substring(blockStart, blockEnd);
          const startLine = source.substring(0, blockStart).split('\n').length;
          const endLine = source.substring(0, blockEnd).split('\n').length;
          
          templateRanges.push({
            startLine,
            endLine,
            text: fullText,
            index: blockStart,
            length: fullText.length
          });
          
          searchFrom = blockEnd;
        } else {
          pos = nextClose.index + nextClose[0].length;
        }
      }
    }
    
    // If we didn't find a match, move past this opening tag
    if (depth > 0) {
      searchFrom = contentStart;
    }
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
function extractChunks(ast, originalSource, templateRanges, fileMetadata) {
  const lines = originalSource.split('\n');
  const chunks = [];
  const hasTemplate = templateRanges.length > 0;
  
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
          endLine: importEnd,
          metadata: {
            imports: fileMetadata.imports,
            frameworks: fileMetadata.frameworks,
          }
        });
        importStart = null;
        importEnd = null;
      }
      
      // Process this node
      const nodeInfo = extractNodeInfo(node, templateRanges, fileMetadata, hasTemplate);
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
      endLine: importEnd,
      metadata: {
        imports: fileMetadata.imports,
        frameworks: fileMetadata.frameworks,
      }
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
        tokenCount: estimateTokens(lines, node.startLine, node.endLine),
        metadata: node.metadata || {}
      });
    } else {
      // Split large node (e.g., class with many methods)
      const subChunks = splitLargeNode(node, lines, templateRanges, fileMetadata);
      chunks.push(...subChunks);
    }
  }
  
  return chunks;
}

/**
 * Extract info from a Babel AST node
 */
function extractNodeInfo(node, templateRanges, fileMetadata, hasTemplate) {
  const baseInfo = {
    startLine: node.loc.start.line,
    endLine: node.loc.end.line
  };
  
  // Extract decorators if present
  const decorators = extractDecorators(node);
  
  // Base metadata that applies to most constructs
  const baseMetadata = {
    decorators,
    usesEmberConcurrency: fileMetadata.usesEmberConcurrency,
    hasTemplate,
    tioUiImports: fileMetadata.tioUiImports,
    frameworks: fileMetadata.frameworks,
  };
  
  switch (node.type) {
    case 'ClassDeclaration':
    case 'ClassExpression': {
      // Check if this class contains a template (Glimmer component)
      const classEnd = expandForTemplates(baseInfo.endLine, templateRanges);
      
      // Extract superclass and protocols (interfaces)
      const { superclass, protocols } = extractClassInheritance(node);
      
      // Extract property decorators from class body
      const propertyDecorators = extractPropertyDecorators(node);
      
      return {
        type: 'class',
        name: node.id?.name || 'anonymous',
        startLine: baseInfo.startLine,
        endLine: classEnd,
        metadata: {
          ...baseMetadata,
          decorators: [...decorators, ...propertyDecorators],
          superclass,
          protocols,
        }
      };
    }
      
    case 'FunctionDeclaration':
      return {
        type: 'function',
        name: node.id?.name || 'anonymous',
        ...baseInfo,
        metadata: baseMetadata
      };
      
    case 'VariableDeclaration': {
      // Check for arrow functions or class expressions
      const decl = node.declarations[0];
      if (decl?.init?.type === 'ArrowFunctionExpression' ||
          decl?.init?.type === 'FunctionExpression') {
        return {
          type: 'function',
          name: decl.id?.name || 'anonymous',
          ...baseInfo,
          metadata: baseMetadata
        };
      }
      if (decl?.init?.type === 'ClassExpression') {
        const { superclass, protocols } = extractClassInheritance(decl.init);
        return {
          type: 'class',
          name: decl.id?.name || 'anonymous',
          ...baseInfo,
          metadata: {
            ...baseMetadata,
            superclass,
            protocols,
          }
        };
      }
      // Skip simple variable declarations (too granular)
      return null;
    }
      
    case 'ExportDefaultDeclaration':
    case 'ExportNamedDeclaration':
      // Recurse into the declaration
      if (node.declaration) {
        const inner = extractNodeInfo(node.declaration, templateRanges, fileMetadata, hasTemplate);
        if (inner) {
          return { ...inner, startLine: baseInfo.startLine };
        }
      }
      return null;
      
    case 'TSInterfaceDeclaration':
      return {
        type: 'interface',
        name: node.id?.name || 'anonymous',
        ...baseInfo,
        metadata: baseMetadata
      };
      
    case 'TSTypeAliasDeclaration':
      return {
        type: 'type',
        name: node.id?.name || 'anonymous',
        ...baseInfo,
        metadata: baseMetadata
      };
      
    case 'TSEnumDeclaration':
      return {
        type: 'enum',
        name: node.id?.name || 'anonymous',
        ...baseInfo,
        metadata: baseMetadata
      };
      
    default:
      return null;
  }
}

/**
 * Extract decorators from a node
 */
function extractDecorators(node) {
  const decorators = [];
  
  if (node.decorators) {
    for (const dec of node.decorators) {
      if (dec.expression) {
        if (dec.expression.type === 'Identifier') {
          decorators.push('@' + dec.expression.name);
        } else if (dec.expression.type === 'CallExpression' && dec.expression.callee) {
          decorators.push('@' + (dec.expression.callee.name || dec.expression.callee.property?.name || 'unknown'));
        }
      }
    }
  }
  
  return decorators;
}

/**
 * Extract property decorators from class body (e.g., @tracked, @service)
 */
function extractPropertyDecorators(classNode) {
  const decorators = new Set();
  
  if (classNode.body && classNode.body.body) {
    for (const member of classNode.body.body) {
      if (member.decorators) {
        for (const dec of member.decorators) {
          if (dec.expression) {
            let name;
            if (dec.expression.type === 'Identifier') {
              name = dec.expression.name;
            } else if (dec.expression.type === 'CallExpression' && dec.expression.callee) {
              name = dec.expression.callee.name || dec.expression.callee.property?.name;
            }
            if (name) {
              decorators.add('@' + name);
            }
          }
        }
      }
    }
  }
  
  return Array.from(decorators);
}

/**
 * Extract superclass and implemented interfaces from a class
 */
function extractClassInheritance(classNode) {
  let superclass = null;
  const protocols = [];
  
  // Superclass
  if (classNode.superClass) {
    if (classNode.superClass.type === 'Identifier') {
      superclass = classNode.superClass.name;
    } else if (classNode.superClass.type === 'MemberExpression') {
      // e.g., React.Component
      superclass = classNode.superClass.object?.name + '.' + classNode.superClass.property?.name;
    }
  }
  
  // TypeScript implements clause
  if (classNode.implements) {
    for (const impl of classNode.implements) {
      if (impl.expression?.name) {
        protocols.push(impl.expression.name);
      }
    }
  }
  
  return { superclass, protocols };
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
function splitLargeNode(node, lines, templateRanges, fileMetadata) {
  const chunks = [];
  const metadata = node.metadata || {};
  
  if (node.type === 'class') {
    // For classes, we could split by methods
    // For now, just create one large chunk (TODO: improve)
    chunks.push({
      startLine: node.startLine,
      endLine: node.endLine,
      text: extractLines(lines, node.startLine, node.endLine),
      constructType: mapConstructType('class'),
      constructName: node.name,
      tokenCount: estimateTokens(lines, node.startLine, node.endLine),
      metadata
    });
  } else {
    // Default: single chunk
    chunks.push({
      startLine: node.startLine,
      endLine: node.endLine,
      text: extractLines(lines, node.startLine, node.endLine),
      constructType: mapConstructType(node.type),
      constructName: node.name,
      tokenCount: estimateTokens(lines, node.startLine, node.endLine),
      metadata
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
  version: '1.1.0'  // Bumped for metadata support
};

export { parseAndChunk };
