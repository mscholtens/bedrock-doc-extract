#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { BedrockDocExtractStack } from '../lib/bedrock-doc-extract-stack';

const app = new cdk.App();

const ebAppName = app.node.tryGetContext('ebAppName') ?? 'bedrock-doc-extract';
const ebEnvName = app.node.tryGetContext('ebEnvName') ?? 'bedrock-doc-extract-env';
const ebSolutionStack =
  app.node.tryGetContext('ebSolutionStack') ??
  '64bit Amazon Linux 2023 v6.10.1 running Node.js 24';
const bedrockModelId =
  app.node.tryGetContext('bedrockModelId') ?? 'anthropic.claude-3-haiku-20240307-v1:0';

new BedrockDocExtractStack(app, 'BedrockDocExtractStack', {
  ebAppName,
  ebEnvName,
  ebSolutionStack,
  bedrockModelId,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    // Keep fixed to the project default region so synth/IAM ARNs match scripts/config.env.
    region: 'eu-central-1',
  },
});
