export type FieldSpec = {
  key: string;
  label: string;
};

export type ExtractResultPayload = {
  filename: string;
  testRun: boolean;
  fields: FieldSpec[];
  values: Record<string, string>;
};
