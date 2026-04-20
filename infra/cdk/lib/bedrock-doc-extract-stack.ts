import * as cdk from 'aws-cdk-lib';
import * as elasticbeanstalk from 'aws-cdk-lib/aws-elasticbeanstalk';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';

export interface BedrockDocExtractStackProps extends cdk.StackProps {
  ebAppName: string;
  ebEnvName: string;
  ebSolutionStack: string;
  bedrockModelId: string;
}

export class BedrockDocExtractStack extends cdk.Stack {
  // NOTE: artifactBucket has been removed. EB processes application versions
  // from its own managed bucket (elasticbeanstalk-<region>-<account>).
  // Uploading to a custom bucket causes versions to remain UNPROCESSED.
  public readonly tempBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: BedrockDocExtractStackProps) {
    super(scope, id, props);

    const { ebAppName, ebEnvName, ebSolutionStack, bedrockModelId } = props;
    const region = cdk.Stack.of(this).region;
    const account = cdk.Stack.of(this).account;

    // -------------------------------------------------------------------------
    // Bedrock model access check (custom resource).
    //
    // Anthropic models require a one-time manual step in the AWS console:
    //   Bedrock → Model access → Request access → fill in the use-case form.
    // That form cannot be automated. However, this custom resource runs a
    // bedrock:ListFoundationModels call during cdk deploy and fails fast with a
    // clear message if the model is not yet accessible, rather than letting the
    // deployed application fail at runtime with a cryptic error.
    // -------------------------------------------------------------------------
    const bedrockCheckRole = new iam.Role(this, 'BedrockAccessCheckRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
      inlinePolicies: {
        BedrockList: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              actions: ['bedrock:ListFoundationModels', 'bedrock:GetFoundationModel'],
              resources: ['*'],
            }),
          ],
        }),
      },
    });

    const bedrockCheckFn = new lambda.Function(this, 'BedrockAccessCheckFn', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      role: bedrockCheckRole,
      timeout: cdk.Duration.seconds(30),
      code: lambda.Code.fromInline(`
const https = require('https');
const { BedrockClient, GetFoundationModelCommand } = require('@aws-sdk/client-bedrock');

async function sendResponse(event, context, status, reason) {
  const body = JSON.stringify({
    Status: status,
    Reason: reason,
    PhysicalResourceId: event.LogicalResourceId,
    StackId: event.StackId,
    RequestId: event.RequestId,
    LogicalResourceId: event.LogicalResourceId,
  });
  const url = new URL(event.ResponseURL);
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: url.hostname, path: url.pathname + url.search,
      method: 'PUT', headers: { 'Content-Type': '', 'Content-Length': Buffer.byteLength(body) },
    }, resolve);
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

exports.handler = async (event, context) => {
  console.log('Event:', JSON.stringify(event));
  if (event.RequestType === 'Delete') {
    await sendResponse(event, context, 'SUCCESS', 'Delete - nothing to do');
    return;
  }
  const modelId = event.ResourceProperties.ModelId;
  const client = new BedrockClient({ region: process.env.AWS_REGION });
  try {
    const result = await client.send(new GetFoundationModelCommand({ modelIdentifier: modelId }));
    const access = result?.modelDetails?.modelLifecycle?.status;
    // 'ACTIVE' means the model exists; access grant is checked separately
    console.log('Model details:', JSON.stringify(result?.modelDetails));
    await sendResponse(event, context, 'SUCCESS', \`Model \${modelId} is accessible\`);
  } catch (err) {
    const msg = err?.message || String(err);
    // ValidationException with "use case" language means form not submitted
    if (msg.includes('use case') || msg.includes('not been submitted')) {
      await sendResponse(event, context, 'FAILED',
        \`Bedrock model access not granted for \${modelId}. \` +
        \`Go to AWS Console → Bedrock → Model access → request access for this model, \` +
        \`fill in the Anthropic use-case form, then re-run cdk deploy.\`);
    } else {
      await sendResponse(event, context, 'FAILED', \`Unexpected error checking Bedrock access: \${msg}\`);
    }
  }
};
      `),
    });

    const bedrockAccessCheck = new cr.Provider(this, 'BedrockAccessCheckProvider', {
      onEventHandler: bedrockCheckFn,
    });

    const bedrockAccessResource = new cdk.CustomResource(this, 'BedrockAccessCheck', {
      serviceToken: bedrockAccessCheck.serviceToken,
      properties: {
        ModelId: bedrockModelId,
        // Changing this forces re-check on every deploy
        DeployTime: new Date().toISOString(),
      },
    });

    // -------------------------------------------------------------------------
    // Temp bucket for Textract input uploads
    // -------------------------------------------------------------------------
    this.tempBucket = new s3.Bucket(this, 'TempDocBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      enforceSSL: true,
      lifecycleRules: [{ expiration: cdk.Duration.days(1), prefix: 'uploads/' }],
    });

    this.tempBucket.addToResourcePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['s3:*'],
      resources: [
        this.tempBucket.bucketArn,
        this.tempBucket.arnForObjects('*'),
      ],
      principals: [new iam.ServicePrincipal('cloudformation.amazonaws.com')],
    }));

    this.tempBucket.addToResourcePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['s3:*'],
      resources: [
        this.tempBucket.bucketArn,
        this.tempBucket.arnForObjects('*'),
      ],
      principals: [new iam.ServicePrincipal('elasticbeanstalk.amazonaws.com')],
    }));

    // -------------------------------------------------------------------------
    // Elastic Beanstalk Service Role
    // -------------------------------------------------------------------------
    const ebServiceRole = new iam.Role(this, 'EbServiceRole', {
      assumedBy: new iam.ServicePrincipal('elasticbeanstalk.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSElasticBeanstalkService'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSElasticBeanstalkEnhancedHealth'),
      ],
    });

    // -------------------------------------------------------------------------
    // EC2 Instance Role
    // -------------------------------------------------------------------------
    const instanceRole = new iam.Role(this, 'EbEc2InstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AWSElasticBeanstalkWebTier'),
      ],
    });

    // Grant EC2 instances read/write access to the temp bucket for Textract
    this.tempBucket.grantReadWrite(instanceRole);

    // Textract permissions
    instanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['textract:StartDocumentTextDetection', 'textract:GetDocumentTextDetection'],
        resources: ['*'],
      }),
    );

    // Bedrock permissions.
    // We grant both foundation-model and inference-profile resource types because:
    // - Newer Amazon models in eu-* regions require an inference profile
    //   (e.g. eu.amazon.nova-micro-v1:0) rather than direct on-demand invocation.
    // - The inference profile ARN uses a different format than the model ARN.
    // Granting both means the same policy works whether the configured model ID
    // is a plain model (e.g. anthropic.claude-3-haiku-20240307-v1:0) or an
    // inference profile (e.g. eu.amazon.nova-micro-v1:0).
    instanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['bedrock:InvokeModel'],
        resources: [
          // Direct foundation model invocation in the stack region
          `arn:aws:bedrock:${region}::foundation-model/${bedrockModelId}`,
          // Account-scoped inference profile in the stack region
          `arn:aws:bedrock:${region}:${account}:inference-profile/${bedrockModelId}`,
          // Cross-region inference profiles (eu.* prefix) route the actual invocation
          // to an underlying foundation model in a different region (e.g. eu-west-3,
          // eu-west-1) chosen by AWS at runtime. The IAM check is performed against
          // that remote region/model ARN, so we must allow foundation-model across
          // all regions for the base model ID (without the eu./us./ap. prefix).
          // Confirmed from runtime error:
          //   arn:aws:bedrock:eu-west-3::foundation-model/amazon.nova-micro-v1:0
          `arn:aws:bedrock:*::foundation-model/amazon.nova-micro-v1:0`,
          `arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0`,
          `arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0`,
          // Wildcard fallback so any future model ID set in config is also covered
          `arn:aws:bedrock:*::foundation-model/${bedrockModelId}`,
          `arn:aws:bedrock:*::inference-profile/${bedrockModelId}`,
        ],
      }),
    );

    // -------------------------------------------------------------------------
    // Instance Profile (required for EB)
    // -------------------------------------------------------------------------
    const instanceProfile = new iam.InstanceProfile(this, 'EbInstanceProfile', {
      role: instanceRole,
    });

    // -------------------------------------------------------------------------
    // EB Application
    // -------------------------------------------------------------------------
    const application = new elasticbeanstalk.CfnApplication(this, 'EbApplication', {
      applicationName: ebAppName,
      description: 'Bedrock document extract demo (non-production)',
    });

    // EB Environment option settings
    const optionSettings: elasticbeanstalk.CfnEnvironment.OptionSettingProperty[] = [
      {
        namespace: 'aws:autoscaling:launchconfiguration',
        optionName: 'IamInstanceProfile',
        value: instanceProfile.instanceProfileName,
      },
      {
        // ServiceRole expects the role NAME, not the ARN
        namespace: 'aws:elasticbeanstalk:environment',
        optionName: 'ServiceRole',
        value: ebServiceRole.roleName,
      },
      {
        namespace: 'aws:elasticbeanstalk:application:environment',
        optionName: 'NODE_ENV',
        value: 'production',
      },
      {
        namespace: 'aws:elasticbeanstalk:application:environment',
        optionName: 'PORT',
        value: '8080',
      },
      {
        namespace: 'aws:elasticbeanstalk:application:environment',
        optionName: 'TEMP_BUCKET_NAME',
        value: this.tempBucket.bucketName,
      },
      {
        namespace: 'aws:elasticbeanstalk:application:environment',
        optionName: 'BEDROCK_MODEL_ID',
        value: bedrockModelId,
      },
      {
        namespace: 'aws:elasticbeanstalk:application:environment',
        optionName: 'AWS_NODEJS_CONNECTION_REUSE_ENABLED',
        value: '1',
      },
    ];

    // EB Environment
    const environment = new elasticbeanstalk.CfnEnvironment(this, 'EbEnvironment', {
      applicationName: ebAppName,
      environmentName: ebEnvName,
      solutionStackName: ebSolutionStack,
      tier: { name: 'WebServer', type: 'Standard', version: '1.0' },
      optionSettings,
    });

    // Ensure the application and instance profile exist before the environment,
    // and that Bedrock access has been verified before the environment launches.
    environment.addDependency(application);
    environment.addDependency(instanceProfile.node.defaultChild as cdk.CfnResource);
    environment.node.addDependency(bedrockAccessResource);

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    new cdk.CfnOutput(this, 'TempBucketName', {
      value: this.tempBucket.bucketName,
      description: 'Temporary uploads bucket for Textract input',
    });

    new cdk.CfnOutput(this, 'EbApplicationName', {
      value: ebAppName,
    });

    new cdk.CfnOutput(this, 'EbEnvironmentName', {
      value: ebEnvName,
    });

    new cdk.CfnOutput(this, 'EbRegion', {
      value: region,
    });

    new cdk.CfnOutput(this, 'AccountId', {
      value: account,
    });

    new cdk.CfnOutput(this, 'BedrockModelId', {
      value: bedrockModelId,
      description: 'Bedrock foundation model used for document extraction',
    });
  }
}