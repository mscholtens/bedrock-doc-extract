import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Claim letter extraction (demo)',
  description: 'Upload a claim letter PDF and extract structured fields (demo, non-production).',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <main>{children}</main>
      </body>
    </html>
  );
}
