use std::{
    fs,
    future::pending,
    path::Path,
    sync::{Arc, Mutex},
};

use rmcp::{
    ErrorData,
    model::{JsonObject, Tool},
};
use serde_json::{Value, json};

#[derive(Default)]
struct Counts {
    received: u64,
    held: u64,
    returned: u64,
}

#[derive(Clone, Default)]
pub struct Load(Arc<Mutex<Counts>>);

impl Load {
    pub fn tools() -> [Tool; 2] {
        let echo = json!({
            "type": "object",
            "properties": {"token": {"type": "string"}, "hold": {"type": "boolean"}},
            "required": ["token"],
        });
        [
            Tool::new(
                "fixture_load_echo",
                "Echo a load probe or hold it open",
                Arc::new(echo.as_object().unwrap().clone()),
            ),
            Tool::new(
                "fixture_load_state",
                "Read this process's load counters",
                Arc::new(json!({"type": "object"}).as_object().unwrap().clone()),
            ),
        ]
    }

    pub fn state(&self) -> String {
        let counts = self.0.lock().unwrap();
        format!(
            "{} {} {} {}",
            std::process::id(),
            counts.received,
            counts.held,
            counts.returned
        )
    }

    pub async fn echo(
        &self,
        arguments: Option<&JsonObject>,
        replacement_audit: Option<&Path>,
    ) -> Result<String, ErrorData> {
        let token = arguments
            .and_then(|args| args.get("token"))
            .and_then(Value::as_str)
            .ok_or_else(|| ErrorData::invalid_params("expected a string token", None))?;
        let hold = match arguments.and_then(|args| args.get("hold")) {
            None => false,
            Some(Value::Bool(value)) => *value,
            Some(_) => return Err(ErrorData::invalid_params("expected a boolean hold", None)),
        };
        {
            let mut counts = self.0.lock().unwrap();
            counts.received += 1;
            if hold {
                counts.held += 1;
            } else {
                counts.returned += 1;
            }
        }
        if hold {
            if let Some(directory) = replacement_audit {
                fs::write(directory.join("load-replayed"), token)
                    .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
            }
            pending().await
        } else {
            Ok(token.to_owned())
        }
    }
}
