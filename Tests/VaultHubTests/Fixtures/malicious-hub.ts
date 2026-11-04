// A malicious Hub for HubAuthLiveTests: what it can do with what a v57 app sends it (protocol.md section 2).
//
//   bun malicious-hub.ts <real hub ws url> <relay port> <claim port>
//
// The relay port answers hub/info by asking the real Hub, so its answers carry the real key and a real proof. It takes any
// connection, and replays each token and certificate it receives on the real Hub, twice, calling an owner-only API.
// The claim port claims the real Hub's key without being able to prove it.
// `report` on either port says what happened. Channel comes from CHANNEL_DIR, or the checkouts next to Vault.
const channelDir = process.env.CHANNEL_DIR ?? new URL('../../../../../Hub/Channel/channel', import.meta.url).pathname
const { Channel: Server } = await import(`${channelDir}/server`)
const { Channel: Client } = await import(`${channelDir}/client`)
const [real, relayPort, claimPort] = process.argv.slice(2)

const realHub = new Client().connect(real)
const realInfo = await realHub.send('hub/info')

const report = { relayed: 0, relayReceived: 0, replays: [] as string[], claimReceived: 0, claimAsked: 0 }

async function replay(headers: Record<string, string>): Promise<string> {
  const client = new Client().connect(real, { headers: () => headers })
  try {
    await client.send('hub/pair/new', undefined, { timeout: 3 })
    return 'owner'
  } catch (error: any) {
    return `${error?.text ?? error?.message ?? error}`
  } finally {
    client.stop()
  }
}

function keyed(headers: Record<string, string | undefined>) {
  const taken: Record<string, string> = {}
  for (const name of ['auth', 'v', 'device']) if (headers[name]) taken[name] = headers[name]!
  return taken
}

new Server()
  .post('report', () => report)
  .post('hub/info', async ({ body }: { body: any }) => {
    report.relayed += 1
    return realHub.send('hub/info', body)
  })
  .post('hub/service/update', () => {})
  .post('hub/profile/update', () => {})
  .stream('hub/devices', async function* () {})
  .listen(Number(relayPort), {
    state(headers: Record<string, string | undefined>) {
      if (headers.auth) {
        report.relayReceived += 1
        const taken = keyed(headers)
        // In order: the second replay shows the token is one-time
        void replay(taken).then(first => {
          report.replays.push(first)
          return replay(taken).then(second => report.replays.push(second))
        })
      }
      return {}
    },
  })

new Server()
  .post('report', () => report)
  .post('hub/info', () => {
    report.claimAsked += 1
    return { key: realInfo.key, protocol: 2, pro: true, mode: 'default-deny', challenge: 'AAAAAAAAAAAAAAAAAAAAAA' }
  })
  .listen(Number(claimPort), {
    state(headers: Record<string, string | undefined>) {
      if (headers.auth || headers.device) report.claimReceived += 1
      return {}
    },
  })

console.log('ready')
