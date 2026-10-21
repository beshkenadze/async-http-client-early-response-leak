# async-http-client: an early response keeps the request body in memory

A server can send a complete response with status >= 300 while the client still uploads a streamed body.
[async-http-client](https://github.com/swift-server/async-http-client) 1.36.2 and `main` (`0171152`) then never stop the task that sends the body.
The task keeps the body iterator and its buffered data in memory.

Fix: [beshkenadze/async-http-client#1](https://github.com/beshkenadze/async-http-client/pull/1).

## Run

```sh
./run.sh                                       # AHC 1.36.2, HTTP/2, buffered (eager) body
AHC_REVISION=0171152 ./run.sh                  # AHC main
AHC_PATH=/path/to/async-http-client ./run.sh   # local checkout
./run.sh --http http1 --body lazy              # other variants
offline/offline.sh 1.36.2                      # no network, uses MockRequestExecutor
```

`run.sh` sends one PUT with a 64 MiB body and no credentials to registry-1.docker.io.
The registry answers 401 while the body still uploads.
After 30 s, the program prints if the body iterator was released and how much memory stays allocated.

## Result

64 MiB PUT, 401 response, 30 s wait. Raw data: [`results/`](results/).

| AHC | Iterator released | Memory kept, eager body | Memory kept, lazy body |
|---|---|---|---|
| 1.36.2, `main` | no | 45–62 MiB | 1.3–1.5 MiB |
| fix | yes | 0.3–0.5 MiB | 0.3–0.5 MiB |

HTTP/1.1 and HTTP/2 give the same result.
The fix rows used `afcf468`, which has the same sources as the branch.

Over HTTP/2, the stream also stays half-open, and `shutdown()` does not complete.
That is a separate bug: [beshkenadze/async-http-client#2](https://github.com/beshkenadze/async-http-client/pull/2).

The trigger in practice: apple/containerization sends each blob upload without credentials first.
See [beshkenadze/containerization-push-leak](https://github.com/beshkenadze/containerization-push-leak).

