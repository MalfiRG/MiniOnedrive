# MiniOneDrive

MiniOneDrive is a PowerShell-based file synchronization tool that continuously monitors a source directory and replicates file changes to a designated replica directory in real time. It leverages extensive file validations, a persistent checkpoint system, and robust error handling to ensure that the replica always mirrors the source accurately.

## Features

- **Real-Time Monitoring:** Uses FileSystemWatcher to detect file creations, modifications, deletions, and renames instantly.
- **Intelligent Synchronization:** Implements a multi-phase validation that checks file existence, size, timestamps, ACLs, and MD5 hashes to determine if synchronization is needed.
- **Checkpoint Management:** Maintains a hidden checkpoint file (.synchashes) that tracks file metadata (hashes, timestamps, ACLs) to avoid unnecessary file transfers.
- **Robust Error Handling:** Employs structured exception handling with detailed logging and a retry mechanism using exponential backoff for transient errors.
- **Configurable Parameters:** Allows configurability of the source folder, replica folder, and log file location via script parameters.

## Architecture and Code Design

MiniOneDrive follows an object-oriented design with clear separation of responsibilities across multiple classes:

| **Class**              | **Responsibility**                                                                                                                                               |
|------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Logger**             | Provides logging functionality using the Singleton pattern to ensure a single log instance per log file.                                                           |
| **CheckpointManager**  | Loads and saves persistent state from a checkpoint file (.synchashes), tracking file hashes, last modified timestamps, and ACL information.                     |
| **FileValidator**      | Determines whether a file requires synchronization by performing multi-phase checks including file size, timestamp, ACL, and content hash comparisons.          |
| **FileSynchronizer**   | Manages file operations by copying updated files, deleting orphan files, and updating checkpoint data accordingly.                                                |
| **FolderSynchronizer** | Orchestrates the synchronization process by initializing FileSystemWatcher for file events, handling debouncing, and coordinating synchronization tasks.      |

## Execution Flow

MiniOneDrive operates in three main phases:

1. **Initialization:**
   - Reads parameters for the source folder, replica folder, and log path.
   - Creates a Logger instance and initializes FolderSynchronizer.
   - Sets up the CheckpointManager, FileValidator, and FileSynchronizer.

2. **Initial Full Synchronization:**
   - Executes a full scan of the source directory using `FullSync` to synchronize new or updated files.
   - Cleans up orphaned files in the replica with `CleanupReplica` to remove files no longer present in the source.

3. **Continuous Monitoring:**
   - Uses FileSystemWatcher to monitor the source directory for changes in real time.
   - Adds detected changes to a pending list and processes them after a debouncing period.
   - Handles file creation, updates, deletions, and renaming events appropriately.
   - Continuously updates and saves the checkpoint file to reflect the latest file states.

## Getting Started

### Prerequisites

- Windows PowerShell (version 5.x or later)
- Appropriate permissions to access the source and replica directories

### Installation and Setup

1. **Clone the Repository.**
2. **Navigate to the Project Directory:**

```sh
cd MiniOneDrive
```

3. **Run the Script:**

Execute the script with your desired parameters. Example:

```sh
.\MiniOneDrive.ps1 -SourceFolder "C:\Files1" -ReplicaFolder "C:\FilesReplica" -LogPath "C:\Logs\MiniOneDrive.log"
```

This command starts the synchronization process, performing an initial full sync and then monitoring changes continuously.

## Customization

You can customize settings such as the debounce timer interval or the retry parameters directly in the script to suit your environment.

## Contributing

Contributions, bug reports, and improvements are welcome. Please submit issues or pull requests to contribute to MiniOneDrive.

## License

This project is licensed under the MIT License. See the LICENSE file for details.
