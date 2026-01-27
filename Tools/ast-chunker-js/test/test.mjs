/**
 * Test the AST chunker with sample files
 */

import { parseAndChunk } from '../src/index.js';

// Test TypeScript
const tsSource = `
import { Component } from '@angular/core';
import { Observable } from 'rxjs';

interface User {
  id: number;
  name: string;
}

export class UserService {
  private users: User[] = [];
  
  getUser(id: number): User | undefined {
    return this.users.find(u => u.id === id);
  }
  
  addUser(user: User): void {
    this.users.push(user);
  }
}

export function formatName(user: User): string {
  return user.name.toUpperCase();
}

const helper = (x: number) => x * 2;
`;

console.log('=== TypeScript Test ===');
const tsResult = JSON.parse(parseAndChunk(tsSource, 'typescript'));
console.log(JSON.stringify(tsResult, null, 2));

// Test GTS (Glimmer TypeScript)
const gtsSource = `
import Component from '@glimmer/component';
import { tracked } from '@glimmer/tracking';
import { action } from '@ember/object';

interface CounterSignature {
  Args: { initial?: number };
}

export default class Counter extends Component<CounterSignature> {
  @tracked count = this.args.initial ?? 0;

  <template>
    <div class="counter">
      <span>Count: {{this.count}}</span>
      <button {{on "click" this.increment}}>+</button>
      <button {{on "click" this.decrement}}>-</button>
    </div>
  </template>

  @action
  increment() {
    this.count++;
  }

  @action
  decrement() {
    this.count--;
  }
}
`;

console.log('\n=== GTS Test ===');
const gtsResult = JSON.parse(parseAndChunk(gtsSource, 'gts'));
console.log(JSON.stringify(gtsResult, null, 2));

// Test JavaScript
const jsSource = `
import express from 'express';

const app = express();

function handleRequest(req, res) {
  res.json({ status: 'ok' });
}

class Router {
  constructor() {
    this.routes = [];
  }
  
  addRoute(path, handler) {
    this.routes.push({ path, handler });
  }
}

export { app, handleRequest, Router };
`;

console.log('\n=== JavaScript Test ===');
const jsResult = JSON.parse(parseAndChunk(jsSource, 'javascript'));
console.log(JSON.stringify(jsResult, null, 2));
