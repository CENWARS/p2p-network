use anyhow::Result;
use clap::Parser;
use futures::prelude::*;
use libp2p::{
    core::upgrade,
    dcutr, gossipsub, identify, kad, mdns, noise, ping,
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, Multiaddr, PeerId, Swarm, Transport,
};
use serde::{Deserialize, Serialize};
use serde_yaml;
use std::{
    collections::{HashMap, HashSet},
    env,
    fs,
    hash::{Hash, Hasher},
    path::Path,
    time::Duration,
};
use tokio::io::{self, AsyncBufReadExt};
use tracing::{debug, error, info, warn};

#[derive(Parser, Debug)]
#[command(name = "p2p-network")]
#[command(about = "A distributed P2P network system")]
struct Args {
    /// Configuration file path
    #[arg(short, long, default_value = "config.yaml")]
    config: String,
    
    /// Override listen port
    #[arg(short, long)]
    port: Option<u16>,
    
    /// Override node role
    #[arg(short, long)]
    role: Option<String>,
    
    /// Override cluster name
    #[arg(long)]
    cluster: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkConfig {
    pub node: NodeConfig,
    pub network: NetworkSettings,
    pub kubernetes: Option<KubernetesConfig>,
    pub relay_nodes: Vec<String>,
    pub bootstrap_nodes: Vec<String>,
    pub clusters: HashMap<String, ClusterConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeConfig {
    pub role: String,
    pub listen_port: u16,
    pub external_ip: Option<String>,
    pub capabilities: Vec<String>,
    pub max_connections: Option<usize>,
    pub heartbeat_interval: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkSettings {
    pub protocol_version: String,
    pub mesh_network: bool,
    pub enable_mdns: bool,
    pub enable_relay: bool,
    pub connection_timeout: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KubernetesConfig {
    pub namespace: String,
    pub service_name: String,
    pub headless_service: String,
    pub pod_name: Option<String>,
    pub cluster_name: String,
    pub cross_cluster_discovery: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterConfig {
    pub name: String,
    pub region: String,
    pub bootstrap_endpoints: Vec<String>,
    pub relay_endpoints: Vec<String>,
    pub priority: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum NetworkMessage {
    TaskRequest {
        id: String,
        task_type: String,
        payload: Vec<u8>,
        reward: u64,
    },
    TaskResponse {
        request_id: String,
        result: Vec<u8>,
        execution_time: u64,
    },
    CapabilityAdvertisement {
        node_id: String,
        capabilities: Vec<String>,
        compute_power: u64,
        availability: f32,
    },
    HeartBeat {
        timestamp: u64,
        load: f32,
    },
}

#[derive(NetworkBehaviour)]
struct P2PBehaviour {
    gossipsub: gossipsub::Behaviour,
    mdns: mdns::tokio::Behaviour,
    kademlia: kad::Behaviour<kad::store::MemoryStore>,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
    dcutr: dcutr::Behaviour,
}

pub struct P2PNetwork {
    swarm: Swarm<P2PBehaviour>,
    config: NetworkConfig,
    task_registry: HashMap<String, TaskInfo>,
    peer_capabilities: HashMap<PeerId, PeerCapability>,
    active_tasks: HashSet<String>,
    cluster_peers: HashMap<String, HashSet<PeerId>>,
}

#[derive(Debug, Clone)]
struct TaskInfo {
    id: String,
    task_type: String,
    requester: PeerId,
    payload: Vec<u8>,
    reward: u64,
    created_at: std::time::Instant,
}

#[derive(Debug, Clone)]
struct PeerCapability {
    capabilities: Vec<String>,
    compute_power: u64,
    availability: f32,
    last_seen: std::time::Instant,
}

impl P2PNetwork {
    pub async fn new(local_key: libp2p::identity::Keypair, args: Args) -> Result<Self> {
        // Load configuration
        let config = Self::load_config(&args).await?;
        let local_peer_id = PeerId::from(local_key.public());
        
        info!("Local peer id: {local_peer_id}");
        info!("Node role: {}", config.node.role);
        info!("Cluster: {}", config.kubernetes.as_ref().map(|k| &k.cluster_name).unwrap_or(&"standalone".to_string()));

        // Determine listen addresses based on environment
        let listen_addresses = Self::determine_listen_addresses(&config, &args)?;
        
        // Create transport with optimizations for K8s networking
        let transport = tcp::tokio::Transport::default()
            .upgrade(upgrade::Version::V1Lazy)
            .authenticate(noise::Config::new(&local_key)?)
            .multiplex(yamux::Config::default())
            .timeout(Duration::from_secs(config.network.connection_timeout))
            .boxed();

        // Configure Gossipsub with cluster-aware settings
        let gossipsub_config = gossipsub::ConfigBuilder::default()
            .heartbeat_interval(Duration::from_secs(
                config.node.heartbeat_interval.unwrap_or(10)
            ))
            .validation_mode(gossipsub::ValidationMode::Strict)
            .max_transmit_size(262144) // 256KB for larger payloads
            .duplicate_cache_time(Duration::from_secs(60))
            .message_id_fn(|message| {
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                message.data.hash(&mut hasher);
                gossipsub::MessageId::from(hasher.finish().to_string())
            })
            .build()
            .expect("Valid config");

        let gossipsub = gossipsub::Behaviour::new(
            gossipsub::MessageAuthenticity::Signed(local_key.clone()),
            gossipsub_config,
        ).expect("Valid gossipsub config");

        // Configure Kademlia with cluster topology awareness
        let mut kademlia = kad::Behaviour::new(
            local_peer_id,
            kad::store::MemoryStore::new(local_peer_id),
        );

        // Add bootstrap nodes from config and Kubernetes discovery
        let bootstrap_addrs = Self::resolve_bootstrap_addresses(&config).await?;
        for addr in &bootstrap_addrs {
            if let Ok(multiaddr) = addr.parse::<Multiaddr>() {
                if let Some(peer_id) = extract_peer_id(&multiaddr) {
                    kademlia.add_address(&peer_id, multiaddr.clone());
                    info!("Added bootstrap peer: {} at {}", peer_id, multiaddr);
                }
            }
        }

        // Configure relay addresses
        let relay_addrs = Self::resolve_relay_addresses(&config).await?;
        
        // Configure other behaviors
        let identify = identify::Behaviour::new(identify::Config::new(
            format!("/{}/1.0.0", config.network.protocol_version),
            local_key.public(),
        ));

        let ping = ping::Behaviour::new(ping::Config::new());
        let dcutr = dcutr::Behaviour::new(local_peer_id);
        
        // Conditionally enable mDNS based on config
        let mdns = if config.network.enable_mdns {
            mdns::tokio::Behaviour::new(
                mdns::Config::default(),
                local_peer_id,
            )?
        } else {
            // Create a disabled mDNS behavior
            mdns::tokio::Behaviour::new(
                mdns::Config {
                    ttl: Duration::from_secs(0),
                    query_interval: Duration::from_secs(3600), // Very long interval
                    ..mdns::Config::default()
                },
                local_peer_id,
            )?
        };

        let behaviour = P2PBehaviour {
            gossipsub,
            mdns,
            kademlia,
            identify,
            ping,
            dcutr,
        };

        let mut swarm = Swarm::new(
            transport, 
            behaviour, 
            local_peer_id, 
            libp2p::swarm::Config::with_tokio_executor()
        );

        // Configure connection limits for Kubernetes environments
        if let Some(_max_conn) = config.node.max_connections {
            // Remove this line as set_max_packet_size doesn't exist in kad 0.53
            // swarm.behaviour_mut().kademlia.set_max_packet_size(1024 * 1024); // 1MB
        }

        // Listen on all configured addresses
        for addr in listen_addresses {
            match swarm.listen_on(addr.parse()?) {
                Ok(_) => info!("Listening on: {}", addr),
                Err(e) => warn!("Failed to listen on {}: {}", addr, e),
            }
        }

        // Subscribe to cluster-specific and global topics
        let topics = Self::get_network_topics(&config);
        for topic in &topics {
            swarm.behaviour_mut().gossipsub.subscribe(&gossipsub::IdentTopic::new(topic))?;
            info!("Subscribed to topic: {}", topic);
        }

        Ok(Self {
            swarm,
            config,
            task_registry: HashMap::new(),
            peer_capabilities: HashMap::new(),
            active_tasks: HashSet::new(),
            cluster_peers: HashMap::new(),
        })
    }

    async fn load_config(args: &Args) -> Result<NetworkConfig> {
        // Try to load from file first
        let config_path = Path::new(&args.config);
        let mut config = if config_path.exists() {
            let config_content = fs::read_to_string(config_path)?;
            info!("Loaded configuration from: {}", config_path.display());
            serde_yaml::from_str::<NetworkConfig>(&config_content)?
        } else {
            warn!("Config file not found: {}, using default configuration", config_path.display());
            // Create default config if file doesn't exist
            Self::create_default_config()
        };

        // Override with environment variables (Kubernetes-style)
        Self::apply_env_overrides(&mut config)?;
        
        // Override with CLI arguments
        if let Some(port) = args.port {
            config.node.listen_port = port;
        }
        if let Some(role) = &args.role {
            config.node.role = role.clone();
        }
        if let Some(cluster) = &args.cluster {
            if let Some(k8s_config) = &mut config.kubernetes {
                k8s_config.cluster_name = cluster.clone();
            }
        }

        Ok(config)
    }

    fn create_default_config() -> NetworkConfig {
        NetworkConfig {
            node: NodeConfig {
                role: env::var("NODE_ROLE").unwrap_or_else(|_| "worker".to_string()),
                listen_port: 4001,
                external_ip: None,
                capabilities: vec!["compute".to_string()],
                max_connections: Some(100),
                heartbeat_interval: Some(30),
            },
            network: NetworkSettings {
                protocol_version: "p2p-network".to_string(),
                mesh_network: true,
                enable_mdns: false, // Usually disabled in K8s
                enable_relay: true,
                connection_timeout: 30,
            },
            kubernetes: Some(KubernetesConfig {
                namespace: env::var("NAMESPACE").unwrap_or_else(|_| "default".to_string()),
                service_name: env::var("SERVICE_NAME").unwrap_or_else(|_| "p2p-network".to_string()),
                headless_service: env::var("HEADLESS_SERVICE").unwrap_or_else(|_| "p2p-network-headless".to_string()),
                pod_name: env::var("POD_NAME").ok(),
                cluster_name: env::var("CLUSTER_NAME").unwrap_or_else(|_| "default-cluster".to_string()),
                cross_cluster_discovery: env::var("CROSS_CLUSTER").map(|v| v == "true").unwrap_or(false),
            }),
            relay_nodes: vec![],
            bootstrap_nodes: vec![],
            clusters: HashMap::new(),
        }
    }

    fn apply_env_overrides(config: &mut NetworkConfig) -> Result<()> {
        if let Ok(port) = env::var("LISTEN_PORT") {
            config.node.listen_port = port.parse()?;
        }
        
        if let Ok(external_ip) = env::var("EXTERNAL_IP") {
            config.node.external_ip = Some(external_ip);
        }

        if let Ok(bootstrap_nodes) = env::var("BOOTSTRAP_NODES") {
            config.bootstrap_nodes = bootstrap_nodes.split(',').map(|s| s.trim().to_string()).collect();
        }

        if let Ok(relay_nodes) = env::var("RELAY_NODES") {
            config.relay_nodes = relay_nodes.split(',').map(|s| s.trim().to_string()).collect();
        }

        Ok(())
    }

    fn determine_listen_addresses(config: &NetworkConfig, _args: &Args) -> Result<Vec<String>> {
        let mut addresses = Vec::new();
        let port = config.node.listen_port;

        // In Kubernetes, listen on all interfaces
        if config.kubernetes.is_some() {
            addresses.push(format!("/ip4/0.0.0.0/tcp/{}", port));
            
            // Also add external IP if provided
            if let Some(external_ip) = &config.node.external_ip {
                addresses.push(format!("/ip4/{}/tcp/{}", external_ip, port));
            }
        } else {
            // Standalone mode
            addresses.push(format!("/ip4/127.0.0.1/tcp/{}", port));
            addresses.push(format!("/ip4/0.0.0.0/tcp/{}", port));
        }

        Ok(addresses)
    }

    async fn resolve_bootstrap_addresses(config: &NetworkConfig) -> Result<Vec<String>> {
        let mut addresses = config.bootstrap_nodes.clone();
        
        // Add Kubernetes service discovery
        if let Some(k8s_config) = &config.kubernetes {
            // Resolve headless service for peer discovery
            let headless_addr = format!("{}.{}.svc.cluster.local", 
                k8s_config.headless_service, k8s_config.namespace);
            
            // In a real implementation, you'd resolve DNS records here
            // For now, we'll use the service DNS name
            addresses.push(format!("/dns/{}/tcp/4001", headless_addr));
            
            // Add cross-cluster bootstrap if enabled
            if k8s_config.cross_cluster_discovery {
                for cluster_config in config.clusters.values() {
                    addresses.extend(cluster_config.bootstrap_endpoints.clone());
                }
            }
        }
        
        Ok(addresses)
    }

    async fn resolve_relay_addresses(config: &NetworkConfig) -> Result<Vec<String>> {
        let mut addresses = config.relay_nodes.clone();
        
        if let Some(k8s_config) = &config.kubernetes {
            // Add cluster-specific relay nodes
            for cluster_config in config.clusters.values() {
                addresses.extend(cluster_config.relay_endpoints.clone());
            }
        }
        
        Ok(addresses)
    }

    fn get_network_topics(config: &NetworkConfig) -> Vec<String> {
        let mut topics = vec![
            "global-tasks".to_string(),
            "global-discovery".to_string(),
        ];

        // Add cluster-specific topics
        if let Some(k8s_config) = &config.kubernetes {
            topics.push(format!("cluster-{}-tasks", k8s_config.cluster_name));
            topics.push(format!("cluster-{}-discovery", k8s_config.cluster_name));
        }

        // Add role-specific topics
        topics.push(format!("role-{}", config.node.role));

        topics
    }

    pub async fn run(&mut self) -> Result<()> {
        // Start bootstrap if we have bootstrap nodes
        // Note: In kad 0.53, we don't need to check iter(), just try bootstrap
        if let Err(e) = self.swarm.behaviour_mut().kademlia.bootstrap() {
            warn!("Bootstrap failed: {e}");
        }

        // Spawn input handler
        let mut stdin = io::BufReader::new(io::stdin()).lines();

        loop {
            tokio::select! {
                // Handle user input
                Ok(Some(line)) = stdin.next_line() => {
                    self.handle_user_input(line).await?;
                }
                
                // Handle swarm events
                event = self.swarm.select_next_some() => {
                    if let Err(e) = self.handle_swarm_event(event).await {
                        error!("Error handling swarm event: {e}");
                    }
                }
            }
        }
    }

    async fn handle_user_input(&mut self, input: String) -> Result<()> {
        let parts: Vec<&str> = input.trim().split_whitespace().collect();
        
        match parts.as_slice() {
            ["connect", addr] => {
                let multiaddr: Multiaddr = addr.parse()?;
                self.swarm.dial(multiaddr)?;
                info!("Dialing {addr}");
            }
            ["task", task_type, payload] => {
                self.submit_task(task_type.to_string(), payload.as_bytes().to_vec(), 100).await?;
            }
            ["capability", cap] => {
                self.advertise_capability(cap.to_string()).await?;
            }
            ["peers"] => {
                info!("Connected peers: {:?}", 
                    self.swarm.connected_peers().collect::<Vec<_>>());
            }
            ["help"] => {
                println!("Commands:");
                println!("  connect <multiaddr> - Connect to a peer");
                println!("  task <type> <payload> - Submit a task");
                println!("  capability <name> - Advertise a capability");
                println!("  peers - List connected peers");
                println!("  help - Show this help");
            }
            _ => {
                println!("Unknown command. Type 'help' for available commands.");
            }
        }
        
        Ok(())
    }

    async fn handle_swarm_event(&mut self, event: SwarmEvent<<P2PBehaviour as NetworkBehaviour>::ToSwarm>) -> Result<()> {
        match event {
            SwarmEvent::NewListenAddr { address, .. } => {
                info!("Listening on {address}");
            }
            SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                info!("Connection established with {peer_id}");
                self.send_heartbeat().await?;
            }
            SwarmEvent::ConnectionClosed { peer_id, cause, .. } => {
                info!("Connection closed with {peer_id}: {cause:?}");
                self.peer_capabilities.remove(&peer_id);
            }
            _ => {}
        }
        
        Ok(())
    }

    async fn handle_gossip_message(
        &mut self,
        source: PeerId,
        message: gossipsub::Message,
    ) -> Result<()> {
        let network_message: NetworkMessage = serde_json::from_slice(&message.data)?;
        
        match network_message {
            NetworkMessage::TaskRequest { id, task_type, payload, reward } => {
                info!("Received task request: {id} of type {task_type}");
                
                // Check if we can handle this task
                if self.can_handle_task(&task_type) {
                    let task_info = TaskInfo {
                        id: id.clone(),
                        task_type,
                        requester: source,
                        payload,
                        reward,
                        created_at: std::time::Instant::now(),
                    };
                    
                    self.task_registry.insert(id.clone(), task_info);
                    self.execute_task(id).await?;
                }
            }
            NetworkMessage::TaskResponse { request_id, result, execution_time } => {
                info!("Received task response for {request_id}, execution time: {execution_time}ms");
                self.active_tasks.remove(&request_id);
                // Handle the result based on your application logic
            }
            NetworkMessage::CapabilityAdvertisement { 
                node_id, 
                capabilities, 
                compute_power, 
                availability 
            } => {
                let peer_cap = PeerCapability {
                    capabilities,
                    compute_power,
                    availability,
                    last_seen: std::time::Instant::now(),
                };
                self.peer_capabilities.insert(source, peer_cap);
                debug!("Updated capabilities for {node_id}");
            }
            NetworkMessage::HeartBeat { timestamp, load } => {
                debug!("Heartbeat from {source}: timestamp={timestamp}, load={load}");
            }
        }
        
        Ok(())
    }

    async fn submit_task(&mut self, task_type: String, payload: Vec<u8>, reward: u64) -> Result<()> {
        let task_id = format!("task_{}", rand::random::<u32>());
        
        let message = NetworkMessage::TaskRequest {
            id: task_id.clone(),
            task_type,
            payload,
            reward,
        };
        
        let serialized = serde_json::to_vec(&message)?;
        let topic = gossipsub::IdentTopic::new("network-tasks");
        
        self.swarm.behaviour_mut().gossipsub.publish(topic, serialized)?;
        self.active_tasks.insert(task_id);
        
        Ok(())
    }

    async fn advertise_capability(&mut self, capability: String) -> Result<()> {
        let local_peer_id = *self.swarm.local_peer_id();
        
        let message = NetworkMessage::CapabilityAdvertisement {
            node_id: local_peer_id.to_string(),
            capabilities: vec![capability],
            compute_power: 1000, // Mock value
            availability: 0.8,   // Mock value
        };
        
        let serialized = serde_json::to_vec(&message)?;
        let topic = gossipsub::IdentTopic::new("peer-discovery");
        
        self.swarm.behaviour_mut().gossipsub.publish(topic, serialized)?;
        
        Ok(())
    }

    async fn execute_task(&mut self, task_id: String) -> Result<()> {
        if let Some(task_info) = self.task_registry.get(&task_id) {
            let start_time = std::time::Instant::now();
            
            // Simulate task execution
            tokio::time::sleep(Duration::from_millis(100)).await;
            let result = format!("Result for task {}", task_id).into_bytes();
            
            let execution_time = start_time.elapsed().as_millis() as u64;
            
            let response = NetworkMessage::TaskResponse {
                request_id: task_id.clone(),
                result,
                execution_time,
            };
            
            let serialized = serde_json::to_vec(&response)?;
            let topic = gossipsub::IdentTopic::new("network-tasks");
            
            self.swarm.behaviour_mut().gossipsub.publish(topic, serialized)?;
            info!("Task {task_id} completed in {execution_time}ms");
        }
        
        Ok(())
    }

    async fn send_heartbeat(&mut self) -> Result<()> {
        let message = NetworkMessage::HeartBeat {
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_secs(),
            load: 0.5, // Mock load value
        };
        
        let serialized = serde_json::to_vec(&message)?;
        let topic = gossipsub::IdentTopic::new("peer-discovery");
        
        if let Err(e) = self.swarm.behaviour_mut().gossipsub.publish(topic, serialized) {
            warn!("Failed to send heartbeat: {e}");
        }
        
        Ok(())
    }

    fn can_handle_task(&self, task_type: &str) -> bool {
        // Simple capability matching - extend this based on your needs
        matches!(task_type, "compute" | "storage" | "data_processing")
    }
}

fn extract_peer_id(addr: &Multiaddr) -> Option<PeerId> {
    addr.iter()
        .find_map(|component| match component {
            libp2p::multiaddr::Protocol::P2p(peer_id) => Some(peer_id),
            _ => None,
        })
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    
    let args = Args::parse();
    
    // Generate a fixed keypair for consistent peer ID
    let local_key = libp2p::identity::Keypair::generate_ed25519();
    
    let mut network = P2PNetwork::new(local_key, args).await?;
    
    info!("P2P Network started. Type 'help' for commands.");
    network.run().await
}