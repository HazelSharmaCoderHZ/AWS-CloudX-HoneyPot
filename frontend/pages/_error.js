export default function Error({ statusCode }) {
  return (
    <div className="min-h-screen bg-navy-950 text-slate-100 flex items-center justify-center">
      <div className="text-center">
        <h1 className="text-4xl font-bold text-rose-400">{statusCode}</h1>
        <p className="mt-2 text-slate-400">An error occurred.</p>
      </div>
    </div>
  )
}

Error.getInitialProps = ({ err, req }) => ({
  statusCode: err ? err.statusCode : 500,
})
