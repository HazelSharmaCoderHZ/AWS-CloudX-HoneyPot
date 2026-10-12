import Document, { Html, Head, Main, NextScript } from 'next/document'

export default class MyDocument extends Document {
  render() {
    return (
      <Html lang="en">
        <Head>
          <meta charSet="utf-8" />
          <style>{`body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }`}</style>
        </Head>
        <body className="bg-navy-950 text-slate-100">
          <Main />
          <NextScript />
        </body>
      </Html>
    )
  }
}
