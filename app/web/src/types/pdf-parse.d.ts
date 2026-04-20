declare module 'pdf-parse' {
  export type PdfParseResult = {
    numpages: number;
    text: string;
  };

  function pdfParse(data: Buffer, options?: unknown): Promise<PdfParseResult>;
  export default pdfParse;
}
