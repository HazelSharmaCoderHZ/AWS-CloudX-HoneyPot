
import "../styles/globals.css";
import Head from "next/head";

export default function App({ Component, pageProps }) {
  return (
    <>
      <Head>
        <title>AWS-CloudX-HoneyPot Dashboard</title>
        <meta
          name="viewport"
          content="width=device-width, initial-scale=1"
        />
        <meta
          name="description"
          content="Local honeypot monitoring dashboard using synthetic Cowrie events."
        />
      </Head>
      <Component {...pageProps} />
    </>
  );
}
