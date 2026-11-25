mod load;

use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{self, ErrorKind},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use rmcp::{
    ErrorData, ServerHandler, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, Implementation,
        ListToolsResult, PaginatedRequestParams, RequestId, ResourceUpdatedNotificationParam,
        ServerCapabilities, ServerConfig, SubscribeRequestParams, SubscriptionFilter, Tool,
        UnsubscribeRequestParams,
    },
    service::{RequestContext, RoleServer, SubscriptionContext, SubscriptionSink},
    transport::stdio,
};
use serde_json::json;

const RESOURCES: [&str; 2] = [
    "fixture://subscriptions/alpha",
    "fixture://subscriptions/beta",
];

fn resource_index(uri: &str) -> Result<usize, ErrorData> {
    RESOURCES
        .iter()
        .position(|known| *known == uri)
        .ok_or_else(|| ErrorData::invalid_params("unknown fixture resource", None))
}

#[derive(Default)]
struct Registrations {
    legacy: [bool; 2],
    modern: HashMap<RequestId, SubscriptionSink>,
    opened: [usize; 2],
    alpha_requested_tools: bool,
}

fn includes(filter: &SubscriptionFilter, uri: &str) -> bool {
    filter
        .resource_subscriptions
        .as_ref()
        .is_some_and(|uris| uris.iter().any(|candidate| candidate == uri))
}

#[derive(Clone, Default)]
struct Fixture {
    registrations: Arc<Mutex<Registrations>>,
    replacement_audit: Option<PathBuf>,
    load: load::Load,
}

// RMCP can cancel the handler by dropping its future. Retire the sink in either case.
struct ListenRegistration<'a> {
    fixture: &'a Fixture,
    request_id: RequestId,
}

impl Drop for ListenRegistration<'_> {
    fn drop(&mut self) {
        self.fixture
            .registrations
            .lock()
            .unwrap()
            .modern
            .remove(&self.request_id);
    }
}

impl Fixture {
    fn state_text(&self) -> String {
        let state = self.registrations.lock().unwrap();
        let [alpha, beta] = std::array::from_fn(|index| {
            usize::from(state.legacy[index])
                + state
                    .modern
                    .values()
                    .filter(|sink| includes(sink.accepted(), RESOURCES[index]))
                    .count()
        });
        format!(
            "{} {alpha} {beta} {} {} {}",
            std::process::id(),
            state.opened[0],
            state.opened[1],
            u8::from(state.alpha_requested_tools),
        )
    }

    fn audit_alpha_attempt(&self) -> io::Result<()> {
        if let Some(directory) = &self.replacement_audit {
            fs::write(directory.join("alpha-attempted"), [])?;
        }
        Ok(())
    }

    async fn publish(
        &self,
        index: usize,
        context: &RequestContext<RoleServer>,
    ) -> Result<usize, ErrorData> {
        let uri = RESOURCES[index];
        let (legacy, sinks) = {
            let state = self.registrations.lock().unwrap();
            let sinks = state
                .modern
                .values()
                .filter(|sink| includes(sink.accepted(), uri))
                .cloned()
                .collect::<Vec<_>>();
            (state.legacy[index], sinks)
        };
        if legacy {
            context
                .peer
                .notify_resource_updated(ResourceUpdatedNotificationParam::new(uri))
                .await
                .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
        }
        for sink in &sinks {
            sink.notify_resource_updated(uri)
                .await
                .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
        }
        Ok(sinks.len() + usize::from(legacy))
    }
}

impl ServerHandler for Fixture {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(
            ServerCapabilities::builder()
                .enable_resources()
                .enable_resources_subscribe()
                .enable_tools()
                .build(),
        )
        .with_server_info(Implementation::new(
            "limb-rmcp-subscriptions",
            env!("CARGO_PKG_VERSION"),
        ))
    }

    async fn subscribe(
        &self,
        request: SubscribeRequestParams,
        _: RequestContext<RoleServer>,
    ) -> Result<(), ErrorData> {
        let index = resource_index(&request.uri)?;
        if index == 0 {
            self.audit_alpha_attempt()
                .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
        }
        let mut state = self.registrations.lock().unwrap();
        state.legacy[index] = true;
        state.opened[index] += 1;
        Ok(())
    }

    async fn unsubscribe(
        &self,
        request: UnsubscribeRequestParams,
        _: RequestContext<RoleServer>,
    ) -> Result<(), ErrorData> {
        self.registrations.lock().unwrap().legacy[resource_index(&request.uri)?] = false;
        Ok(())
    }

    fn accepted_subscription_filter(
        &self,
        requested: &SubscriptionFilter,
    ) -> Option<SubscriptionFilter> {
        // Observe the request before RMCP sends the ACK or starts listen().
        let [alpha, beta] = RESOURCES.map(|uri| includes(requested, uri));
        if alpha {
            self.audit_alpha_attempt()
                .expect("write replacement subscription audit");
        }
        {
            let mut state = self.registrations.lock().unwrap();
            state.opened[0] += usize::from(alpha);
            state.opened[1] += usize::from(beta);
            if alpha {
                state.alpha_requested_tools = requested.tools_list_changed == Some(true);
            }
        }
        let mut accepted = requested.clone();
        if let Some(uris) = &mut accepted.resource_subscriptions {
            uris.retain(|uri| RESOURCES.contains(&uri.as_str()));
        }
        Some(accepted)
    }

    async fn listen(&self, context: SubscriptionContext) -> Result<(), ErrorData> {
        let sink = context.sink();
        let request_id = sink.id().clone();
        let registration = ListenRegistration {
            fixture: self,
            request_id: request_id.clone(),
        };
        self.registrations
            .lock()
            .unwrap()
            .modern
            .insert(request_id, sink.clone());
        context.cancelled().await;
        drop(registration);
        Ok(())
    }

    async fn list_tools(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let mut tools = vec![
            Tool::new("fixture_state", "Read the process ID and registration counters", Arc::new(
                json!({"type":"object"}).as_object().unwrap().clone()
            )),
            Tool::new("fixture_publish", "Publish a change for one fixture resource", Arc::new(
                json!({"type":"object", "properties":{"uri":{"type":"string"}}, "required":["uri"]})
                    .as_object().unwrap().clone()
            )),
        ];
        tools.extend(load::Load::tools());
        Ok(ListToolsResult::with_all_items(tools))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let text = match request.name.as_ref() {
            "fixture_state" => self.state_text(),
            "fixture_load_state" => self.load.state(),
            "fixture_load_echo" => {
                self.load
                    .echo(
                        request.arguments.as_ref(),
                        self.replacement_audit.as_deref(),
                    )
                    .await?
            }
            "fixture_publish" => {
                let uri = request
                    .arguments
                    .as_ref()
                    .and_then(|args| args.get("uri"))
                    .and_then(|uri| uri.as_str())
                    .ok_or_else(|| ErrorData::invalid_params("expected a resource URI", None))?;
                self.publish(resource_index(uri)?, &context)
                    .await?
                    .to_string()
            }
            _ => return Err(ErrorData::invalid_params("unknown fixture tool", None)),
        };
        Ok(CallToolResult::success(vec![ContentBlock::text(text)]).into())
    }
}

async fn gate_relaunch(directory: &Path) -> io::Result<bool> {
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(directory.join("started"))
    {
        Ok(_) => return Ok(false),
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let pid_file = directory.join("relaunch-pid.pending");
    fs::write(&pid_file, std::process::id().to_string())?;
    fs::rename(pid_file, directory.join("relaunch-pid"))?;

    let release = directory.join("allow-relaunch");
    let wait = async {
        while !release.try_exists()? {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        Ok::<(), io::Error>(())
    };
    tokio::time::timeout(Duration::from_secs(15), wait).await??;
    Ok(true)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut fixture = Fixture::default();
    if let Some(directory) = std::env::args_os().nth(1) {
        let directory = PathBuf::from(directory);
        if gate_relaunch(&directory).await? {
            fixture.replacement_audit = Some(directory);
        }
    }
    let server = fixture.serve(stdio()).await?;
    server.waiting().await?;
    Ok(())
}
