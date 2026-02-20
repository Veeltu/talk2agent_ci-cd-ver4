import os
import json
import google.auth
import google.auth.transport.requests
from google.oauth2 import service_account
from google.adk.tools.apihub_tool.apihub_toolset import APIHubToolset
from google.adk.tools.function_tool import FunctionTool
from google.adk.tools.agent_tool import AgentTool
from google.adk.agents.llm_agent import LlmAgent
from google.adk.auth.auth_credential import AuthCredential, AuthCredentialTypes

# ==============================================================================
# API HUB CONFIGURATION - Read lazily to allow .env loading
# ==============================================================================

_SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]

def get_apihub_access_token() -> str:
    """Get a fresh access token for API Hub.
    Uses APIHUB_SA_KEY_JSON (SA key as env var) if set, otherwise falls back to ADC.
    """
    try:
        sa_json = os.getenv("APIHUB_SA_KEY_JSON")
        if sa_json:
            creds = service_account.Credentials.from_service_account_info(json.loads(sa_json), scopes=_SCOPES)
        else:
            creds, _ = google.auth.default(scopes=_SCOPES)
        creds.refresh(google.auth.transport.requests.Request())
        return creds.token
    except Exception as e:
        print(f"[WARN] Auth failed ({e}), falling back to APIHUB_ACCESS_TOKEN env var")
        return os.getenv("APIHUB_ACCESS_TOKEN", "")

def get_apihub_search_url() -> str:
    """Get API Hub search URL (read lazily after .env is loaded)."""
    return os.getenv("APIHUB_SEARCH_URL", "")

def get_apikey_credential() -> str:
    """Get API key credential (read lazily after .env is loaded)."""
    return os.getenv("APIKEY_CREDENTIAL", "")

def get_auth_credential() -> AuthCredential | None:
    """Create API Key auth credential if configured."""
    api_key = get_apikey_credential()
    if api_key:
        return AuthCredential(
            auth_type=AuthCredentialTypes.API_KEY,
            api_key=api_key
        )
    return None


# ==============================================================================
# DYNAMIC AGENT STORAGE - Stores dynamically created execution agent
# ==============================================================================

_execution_agent: LlmAgent | None = None
_execution_agent_tool: AgentTool | None = None
_current_tools: list[str] = []  # Track what tools current agent has


def reset_execution_agent() -> dict:
    """
    Destroy the current execution agent to allow creating a new one.
    Call this when you need different tools than currently available.
    
    Returns:
        Confirmation that the agent was reset
    """
    global _execution_agent, _execution_agent_tool, _current_tools
    
    old_tools = _current_tools.copy()
    _execution_agent = None
    _execution_agent_tool = None
    _current_tools = []
    
    print(f"[RESET] Destroyed execution agent with tools: {old_tools}")
    return {
        "success": True,
        "message": "Execution agent destroyed. Call discover_and_create_agent with a new query.",
        "previous_tools": old_tools
    }


def create_toolset_from_apihub(apihub_resource_name: str, name: str = "discovered-api", description: str = "Discovered API") -> APIHubToolset | None:
    """Create an APIHubToolset from an API Hub resource name."""
    print(f"[CREATE] Creating toolset from API Hub: {name}")
    try:
        toolset = APIHubToolset(
            name=name,
            description=description,
            access_token=get_apihub_access_token(),
            apihub_resource_name=apihub_resource_name,
            # Don't pass auth_credential here - we'll configure per tool
        )
        return toolset
    except Exception as e:
        print(f"[ERROR] Failed to create toolset from {apihub_resource_name}: {e}")
        return None


# ==============================================================================
# SEARCH API HUB - Find APIs by semantic query
# ==============================================================================

async def search_api_hub(query: str) -> str | None:
    """
    Search API Hub for relevant APIs using semantic search.
    
    Args:
        query: Natural language query describing the API capability needed
    
    Returns:
        The spec resource name (apihub_resource_name) or None if not found
    """
    import requests
    
    search_url = get_apihub_search_url()
    access_token = get_apihub_access_token()
    
    if not search_url:
        print("[ERROR] APIHUB_SEARCH_URL not configured in .env")
        return None
    
    if not access_token:
        print("[ERROR] Could not obtain access token (check ADC / GOOGLE_APPLICATION_CREDENTIALS)")
        return None
    
    print(f"[SEARCH] Searching API Hub for: '{query}'")
    
    # Make the search request
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json"
    }
    
    payload = {
        "query": query,
        "filter": "resource_type = ApiOperation",
        "pageSize": 1
    }
    
    try:
        response = requests.post(search_url, headers=headers, json=payload)
        response.raise_for_status()
        
        data = response.json()
        
        # Extract spec from first search result
        search_results = data.get("searchResults", [])
        if not search_results:
            print(f"[SEARCH] No results found for: '{query}'")
            return None
        
        # Get the spec resource name from the first result
        first_result = search_results[0]
        spec = first_result.get("resource", {}).get("operation", {}).get("spec")
        
        if spec:
            print(f"[SEARCH] Found spec: {spec}")
            return spec
        else:
            print(f"[SEARCH] No spec in result: {first_result}")
            return None
            
    except requests.exceptions.RequestException as e:
        print(f"[ERROR] API Hub search failed: {e}")
        return None


# ==============================================================================
# DISCOVER AND CREATE EXECUTION AGENT
# ==============================================================================

async def discover_and_create_agent(query: str) -> dict:
    """
    Search API Hub, create toolset, and create a NEW execution agent with those tools.
    
    This REPLACES any existing execution agent with a new one.
    Call this whenever you need different tools.
    
    Args:
        query: Semantic search query describing the API capability needed
    
    Returns:
        dict with agent status and available tools
    """
    global _execution_agent, _execution_agent_tool, _current_tools
    
    # Step 0: Destroy any existing execution agent
    if _execution_agent is not None:
        print(f"[RESET] Replacing existing agent (had tools: {_current_tools})")
        _execution_agent = None
        _execution_agent_tool = None
        _current_tools = []
    
    # Step 1: Search API Hub
    apihub_resource_name = await search_api_hub(query)
    
    if not apihub_resource_name:
        return {
            "success": False,
            "message": f"No API found matching: {query}"
        }
    
    # Step 2: Create toolset with REAL API tools
    toolset = create_toolset_from_apihub(
        apihub_resource_name=apihub_resource_name,
        name="discovered-api",
        description=f"API discovered for: {query}"
    )
    
    if toolset is None:
        return {
            "success": False,
            "message": f"Failed to parse API spec for: {query}. The spec may be malformed.",
            "spec": apihub_resource_name
        }
    
    # Step 3: Get tools and configure auth
    tools = await toolset.get_tools()
    tool_names = [tool.name for tool in tools]
    _current_tools = tool_names  # Track current tools
    
    # Configure API Key auth on tools that need it
    auth_cred = get_auth_credential()
    if auth_cred:
        for tool in tools:
            if hasattr(tool, 'auth_scheme') and tool.auth_scheme:
                tool.configure_auth_credential(auth_cred)
    
    print(f"[OK] Discovered {len(tool_names)} tools: {tool_names}")
    
    # Step 4: Create a NEW execution agent with the REAL tools
    _execution_agent = LlmAgent(
        model='gemini-2.0-flash',
        name='api_execution_agent',
        description=f'Executes API calls for: {query}',
        instruction=f'''You are an API Execution Agent with access to real API tools.

You have ONLY these tools available:
{chr(10).join(f"- {name}" for name in tool_names)}

IMPORTANT: If you cannot fulfill the request with your available tools, 
respond with EXACTLY: "TOOL_NOT_FOUND: <description of what tool is needed>"

When you CAN fulfill the request:
1. Identify which tool to use
2. Call the tool with the correct parameters
3. Return the result

Be precise with parameter names - use exactly what the tool expects.
''',
        tools=[toolset],  # <-- REAL tools, not proxy!
    )
    
    # Step 5: Wrap the agent as a tool so it can be called
    _execution_agent_tool = AgentTool(agent=_execution_agent)
    
    return {
        "success": True,
        "message": f"Created execution agent with {len(tool_names)} tools",
        "tools": tool_names,
        "instruction": "Now use 'call_execution_agent' to execute API calls"
    }


async def call_execution_agent(request: str) -> dict:
    """
    Call the dynamically created execution agent.
    
    IMPORTANT: Call discover_and_create_agent first!
    
    Args:
        request: What you want the execution agent to do (e.g., "get customer 123")
    
    Returns:
        The result from the execution agent
    """
    global _execution_agent
    
    if _execution_agent is None:
        return {
            "error": "No execution agent created. Call discover_and_create_agent first."
        }
    
    print(f"[CALL] Calling execution agent with: {request}")
    
    try:
        from google.adk.runners import Runner
        from google.adk.sessions import InMemorySessionService
        from google.genai.types import Content, Part
        
        # Create a runner for the execution agent
        session_service = InMemorySessionService()
        runner = Runner(
            agent=_execution_agent,
            app_name="execution_agent",
            session_service=session_service
        )
        
        # Create a session
        session = await session_service.create_session(
            app_name="execution_agent",
            user_id="user"
        )
        
        # Create the user message
        user_content = Content(
            role="user",
            parts=[Part(text=request)]
        )
        
        # Run the agent - collect the last text response from model
        final_response = None
        async for event in runner.run_async(
            session_id=session.id,
            user_id="user",
            new_message=user_content
        ):
            # We only care about events with text content from the model
            if hasattr(event, 'content') and event.content and hasattr(event.content, 'parts'):
                for part in event.content.parts:
                    if hasattr(part, 'text') and part.text:
                        final_response = part.text
        
        print(f"[RESULT] {final_response}")
        
        # Check if execution agent signaled it doesn't have the right tool
        if final_response and "TOOL_NOT_FOUND" in final_response:
            return {
                "success": False,
                "tool_not_found": True,
                "message": final_response,
                "current_tools": _current_tools,
                "instruction": "Call discover_and_create_agent with a DIFFERENT query."
            }
        
        return {"success": True, "result": final_response}
    except Exception as e:
        import traceback
        traceback.print_exc()
        return {"error": f"Execution agent failed: {str(e)}"}


# ==============================================================================
# EXPOSE AS ADK TOOLS
# ==============================================================================

search_api_hub_tool = FunctionTool(func=search_api_hub)
discover_and_create_agent_tool = FunctionTool(func=discover_and_create_agent)
call_execution_agent_tool = FunctionTool(func=call_execution_agent)
reset_execution_agent_tool = FunctionTool(func=reset_execution_agent)

