use std::{
    collections::BTreeMap,
    env,
    error::Error,
    future::pending,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use rmcp::{
    ClientHandler, ClientLifecycleMode, ClientServiceExt, ErrorData, ServerHandler, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ClientCapabilities, ClientConfig,
        ContentBlock, Implementation, ListToolsResult, PaginatedRequestParams, ProtocolVersion,
        ServerCapabilities, ServerConfig, Tool,
    },
    service::{RequestContext, RoleServer},
    transport::{TokioChildProcess, stdio},
};
use serde_json::json;
use tokio::{process::Command, task::JoinSet};

#[derive(Default)]
struct Server(AtomicUsize);

impl ServerHandler for Server {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("rmcp-system", "1"))
    }

    async fn list_tools(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let schema = json!({
            "type":"object", "required":["token"],
            "properties":{"token":{"type":"string"}, "responseBytes":{"type":"integer"}}
        });
        Ok(ListToolsResult::with_all_items(vec![Tool::new(
            "system_echo",
            "Echo the supplied token or return ASCII bytes",
            Arc::new(schema.as_object().unwrap().clone()),
        )]))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let text = match request.name.as_ref() {
            "system_echo" => {
                let args = request.arguments.as_ref();
                let token = args
                    .and_then(|a| a.get("token"))
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| ErrorData::invalid_params("expected a string token", None))?;
                match args
                    .and_then(|a| a.get("responseBytes"))
                    .and_then(serde_json::Value::as_u64)
                {
                    Some(length) => "x".repeat(length.min(3_000_000) as usize),
                    None => token.to_owned(),
                }
            }
            "system_state" => format!("{} {}", std::process::id(), self.0.load(Ordering::Relaxed)),
            "system_hold" => {
                self.0.fetch_add(1, Ordering::Relaxed);
                pending().await
            }
            _ => return Err(ErrorData::invalid_params("unknown fixture tool", None)),
        };
        Ok(CallToolResult::success(vec![ContentBlock::text(text)]).into())
    }
}

struct Client(ProtocolVersion);

impl ClientHandler for Client {
    fn get_info(&self) -> ClientConfig {
        ClientConfig::new(
            ClientCapabilities::default(),
            Implementation::new("rmcp-system", "1"),
        )
        .with_protocol_version(self.0.clone())
    }
}

#[derive(Default)]
struct Counts {
    completed: usize,
    bytes: usize,
    histogram: BTreeMap<u64, usize>,
    errors: BTreeMap<String, usize>,
    maximum: u64,
}

impl Counts {
    fn record(&mut self, time: u64, bytes: usize) {
        self.completed += 1;
        self.bytes += bytes;
        self.maximum = self.maximum.max(time);
        let mut unit = 1;
        while time / unit >= 100 {
            unit *= 10;
        }
        *self.histogram.entry(time / unit * unit).or_default() += 1;
    }

    fn merge(&mut self, other: Self) {
        self.completed += other.completed;
        self.bytes += other.bytes;
        self.maximum = self.maximum.max(other.maximum);
        for (key, count) in other.histogram {
            *self.histogram.entry(key).or_default() += count;
        }
        for (key, count) in other.errors {
            *self.errors.entry(key).or_default() += count;
        }
    }
}

fn setting(name: &str, fallback: usize) -> usize {
    env::var(format!("LIMB_SYSTEM_{name}"))
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(fallback)
}

async fn run_client(path: &str, args: &[String]) -> Result<bool, Box<dyn Error>> {
    let requested = env::var("LIMB_SYSTEM_REVISION").unwrap_or_else(|_| "2026-07-28".into());
    let revision = match requested.as_str() {
        "2025-03-26" => ProtocolVersion::V_2025_03_26,
        "2025-06-18" => ProtocolVersion::V_2025_06_18,
        "2025-11-25" => ProtocolVersion::V_2025_11_25,
        "2026-07-28" | "auto" => ProtocolVersion::V_2026_07_28,
        _ => return Err("invalid revision".into()),
    };
    let mode = env::var("LIMB_SYSTEM_MODE").unwrap_or_else(|_| "steady".into());
    let workers = setting("WORKERS", 32).max(1);
    let epochs = setting("EPOCHS", 1).max(1);
    let duration = Duration::from_secs(setting("SECONDS", 3).max(1) as u64);
    let operations = setting("OPERATIONS", 0);
    let connect_start = Instant::now();
    let mut command = Command::new(path);
    command.args(args);
    let lifecycle = match requested.as_str() {
        "auto" => ClientLifecycleMode::Auto {
            preferred_versions: vec![revision.clone()],
            legacy_version: None,
        },
        "2026-07-28" => ClientLifecycleMode::Discover {
            preferred_versions: vec![revision.clone()],
        },
        _ => ClientLifecycleMode::Initialize,
    };
    let service = tokio::time::timeout(
        Duration::from_secs(8),
        Client(revision).serve_with_lifecycle(TokioChildProcess::new(command)?, lifecycle),
    )
    .await??;
    let negotiated = &service
        .peer_info()
        .ok_or("missing peer info")?
        .protocol_version;
    println!(
        "{}",
        json!({"event":"connected", "revision":negotiated.to_string(),
        "pid":std::process::id(), "connection_us":connect_start.elapsed().as_micros() as u64})
    );
    if requested != "auto" && negotiated.to_string() != requested {
        service.cancel().await?;
        return Err("unexpected negotiated revision".into());
    }
    let mut clean = true;
    for epoch in 0..epochs {
        let start = Instant::now();
        let mut group = JoinSet::new();
        for worker in 0..workers {
            let peer = service.peer().clone();
            let mode = mode.clone();
            group.spawn(async move {
                let mixed = mode == "mixed" || mode == "large";
                let medium = if mixed {
                    "y".repeat(65_536)
                } else {
                    String::new()
                };
                let large = if mixed {
                    "z".repeat(1_048_576)
                } else {
                    String::new()
                };
                let answer = if mixed {
                    "x".repeat(1_048_576)
                } else {
                    String::new()
                };
                let mut counts = Counts::default();
                let mut sequence = worker;
                while if operations > 0 {
                    sequence < operations
                } else {
                    start.elapsed() < duration
                } {
                    let prefix = format!("{epoch}/{worker}/{sequence}/é\\n");
                    let shape = sequence % 1024;
                    let big = (mode == "mixed" && shape < 2) || mode == "large";
                    let medium_request = mode == "mixed" && shape % 128 == 2;
                    let large_reply = big && shape % 2 == 0;
                    let token = if large_reply {
                        prefix
                    } else if big {
                        prefix + &large
                    } else if medium_request {
                        prefix + &medium
                    } else {
                        prefix
                    };
                    let expected = if large_reply { &answer } else { &token };
                    let begin = Instant::now();
                    let args = if large_reply {
                        json!({"token":token, "responseBytes":answer.len()})
                    } else {
                        json!({"token":token})
                    };
                    let call = peer.call_tool(
                        CallToolRequestParams::new("system_echo")
                            .with_arguments(args.as_object().unwrap().clone()),
                    );
                    let outcome = match tokio::time::timeout(Duration::from_secs(10), call).await {
                        Ok(Ok(result))
                            if result.is_error != Some(true)
                                && result.content.len() == 1
                                && result.content[0]
                                    .as_text()
                                    .is_some_and(|text| &text.text == expected) =>
                        {
                            None
                        }
                        Ok(Ok(_)) => Some("invalid reply".into()),
                        Ok(Err(error)) => Some(error.to_string().chars().take(220).collect()),
                        Err(_) => Some("timed out".into()),
                    };
                    if let Some(error) = outcome {
                        *counts.errors.entry(error).or_default() += 1;
                        if operations == 0 && counts.errors.values().sum::<usize>() >= 4 {
                            break;
                        }
                    } else {
                        counts.record(
                            begin.elapsed().as_micros() as u64,
                            token.len() + expected.len(),
                        );
                    }
                    sequence += workers;
                }
                counts
            });
        }
        let mut counts = Counts::default();
        while let Some(count) = group.join_next().await {
            counts.merge(count?);
        }
        println!(
            "{}",
            json!({"event":"epoch","epoch":epoch,"duration_us":start.elapsed().as_micros() as u64,
            "completed":counts.completed,"errors":counts.errors,"payload_bytes":counts.bytes,
            "histogram_us":counts.histogram,"max_us":counts.maximum})
        );
        if !counts.errors.is_empty() || counts.completed == 0 {
            clean = false;
            break;
        }
    }
    service.cancel().await?;
    Ok(clean)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.first().is_some_and(|arg| arg == "client") {
        if !run_client(args.get(1).ok_or("missing server path")?, &args[2..]).await? {
            std::process::exit(1);
        }
    } else {
        Server::default().serve(stdio()).await?.waiting().await?;
    }
    Ok(())
}
