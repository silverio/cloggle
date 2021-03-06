#define MAX_NEIGHBORS 8
#define MAX_WORD_LEN 16
#define BOARD_SIDE 5
#define DIE_FACES 6
#define BOARD_SIZE (BOARD_SIDE*BOARD_SIDE)
#define MAX_TRIE_SIZE 1100

#define NUM_MUTATE_TYPES      5

#define MUTATE_SWAP_RANDOM    0
#define MUTATE_SWAP_NEIGHBORS 1
#define MUTATE_ROLL_FACE      2
#define MUTATE_ROLL_FACE2     3
#define MUTATE_SWAP_ROLL      4

#define MAX_SWAPS             11
#define MAX_ROLLS             11

#define MAX_PLATEAU_AGE       1000

//  trie node
typedef struct {
  uchar   score;          //  node score, assuming terminal if non-0
  uchar   num_edges;      //  number of outgoing edges
  ushort  edges_offset;   //  offset in the edge label/target arrays
} TrieNodeCL;

typedef struct {
  unsigned short  score;
  unsigned short  age;
  unsigned char   cells[BOARD_SIZE];
  //  want to be the board struct 32-bytes aligned for access efficiency
  unsigned char   __padding[32 - BOARD_SIZE - sizeof(unsigned short) * 2];
} BoardCL;

//  poor-man random number generator (stolen from Java library implementation)
ulong rnd(ulong* seed) {
  return *seed = ((*seed) * 0x5DEECE66DL + 0xBL)&(((ulong)1 << 48) - 1);
}

//  shuffle array in-place (Fischer-Yites)
void shuffle_board(uchar* board, ulong* seed) {
  for (int i = 0; i < BOARD_SIZE; i++) {
    int swap_with = rnd(seed)%(BOARD_SIZE - i);
    char tmp = board[swap_with];
    board[swap_with] = board[i];
    board[i] = tmp;
  }
}

//  creates a random board from the set of dice
void make_random_board(uchar* board, constant const uchar* c_num_dice, ulong* seed) {
  for (int i = 0; i < BOARD_SIZE; i++) {
    board[i] = (unsigned char)(i*DIE_FACES + rnd(seed)%c_num_dice[i]);
  }
  shuffle_board(board, seed);
}
//  returns a random cell index
uchar rnd_cell(ulong* seed) {
  return rnd(seed)%BOARD_SIZE;
}

void swap(unsigned char* arr, int i, int j) {
  unsigned char tmp = arr[i];
  arr[i] = arr[j];
  arr[j] = tmp;
}

uchar die_offs(uchar die) {
  return (die/DIE_FACES)*DIE_FACES;
}

void random_flip(uchar* board, int pos, constant const uchar* c_num_dice, ulong* seed) {
  uchar offs = board[pos]/DIE_FACES;
  int d = rnd(seed) % c_num_dice[offs];
  board[pos] = d + offs*DIE_FACES;
}

//  evaluates the board score
ushort eval_board(
  constant const TrieNodeCL*  c_trie_nodes,
  int                         c_num_trie_nodes,
  constant const char*        c_trie_edge_labels,
  constant const ushort*      c_trie_edge_targets,
  constant const char*        c_dice,
  constant const char*        c_cell_neighbors,
  const uchar*                board
) {
  uchar visited_nodes[MAX_TRIE_SIZE] = {};
  ushort score = 0;

  for (int j = 0; j < BOARD_SIZE; j++) {
    //  "recursively" depth-first search inside the trie and bard in parallel
    uchar visited_faces[BOARD_SIZE] = {};

    uchar cell_stack[MAX_WORD_LEN];
    ushort node_stack[MAX_WORD_LEN];
    uchar cur_neighbor_stack[MAX_WORD_LEN];
      
    int depth = 0;

    cell_stack[0] = j;
    node_stack[0] = 0;
    cur_neighbor_stack[0] = 0;
    visited_faces[0] = 0;

    do {
      int cell = cell_stack[depth];
      int node = node_stack[depth];
      bool backtrack = true;
      if (cur_neighbor_stack[depth] == 0) {
        //  find the outgoing edge, corresponding to the current cell
        char c = c_dice[board[cell]];
        int edge_offs = c_trie_nodes[node].edges_offset;
        int num_edges = (int)c_trie_nodes[node].num_edges;
        node = -1;
        for (int k = 0; k < num_edges; k++) {
          if (c_trie_edge_labels[edge_offs + k] == c) {
            node = c_trie_edge_targets[edge_offs + k];
            //  the prefix also may be a full word, add the score
            score += (ushort)c_trie_nodes[node].score*(1 - (visited_nodes[node/8] >> (node%8))&1);
            visited_nodes[node/8] |= (1 << (node%8));
            break;
          }
        }
      }
          
      if (node >= 0) {
        //  go down, depth-first
        node_stack[depth] = node;
        visited_faces[cell] = 1;
        int neighbor_cell = -1;
        do {
          neighbor_cell = c_cell_neighbors[cur_neighbor_stack[depth] + (MAX_NEIGHBORS + 1)*cell];
          cur_neighbor_stack[depth]++;
        } while (neighbor_cell >= 0 && visited_faces[neighbor_cell]);

        if (neighbor_cell > -1) {
          backtrack = false;
          depth++;
          cell_stack[depth] = neighbor_cell;
          node_stack[depth] = node;
          cur_neighbor_stack[depth] = 0;
        }
      } 
        
      if (backtrack) {
        visited_faces[cell] = 0;
        depth--;
      }
    } while (depth >= 0);
  }
  return score;
}

//  grinding kernel 
kernel void grind(
  constant const TrieNodeCL*  c_trie_nodes,
  int                         c_num_trie_nodes,
  constant const char*        c_trie_edge_labels,
  constant const ushort*      c_trie_edge_targets,
  constant const char*        c_dice,
  constant const uchar*       c_num_dice,
  constant const char*        c_cell_neighbors,
  global BoardCL*             g_boards)
{
  int id = get_global_id(0);
  uchar board[BOARD_SIZE];
  uchar best_board[BOARD_SIZE];

  ushort best_score = g_boards[id].score;
  ulong seed = id * 7 + best_score*(g_boards[id].age + 1);

  if (g_boards[id].age >= MAX_PLATEAU_AGE) {
    //  first iteration, or score plateaued, init fresh
    make_random_board(board, c_num_dice, &seed);
    for (int j = 0; j < BOARD_SIZE; j++) best_board[j] = board[j];
    g_boards[id].age = 0;
    best_score = 0;
  } else {
    for (int j = 0; j < BOARD_SIZE; j++) best_board[j] = g_boards[id].cells[j];
  }
  
  int mutateType = rnd(&seed) % NUM_MUTATE_TYPES;
  int pivot_cell = rnd_cell(&seed);
  int pivot_cell2 = rnd_cell(&seed);

  const int MUTATE_STEPS[] = { BOARD_SIZE, MAX_NEIGHBORS, DIE_FACES, DIE_FACES*DIE_FACES, BOARD_SIZE };
  int nsteps = MUTATE_STEPS[mutateType];

  for (int i = 0; i < nsteps; i++) {
    for (int j = 0; j < BOARD_SIZE; j++) {
      board[j] = best_board[j];
    }

    switch (mutateType) {
    case MUTATE_SWAP_RANDOM: {
      swap(board, i, pivot_cell);
    } break;
    case MUTATE_SWAP_NEIGHBORS: {
      int neighbor = c_cell_neighbors[i + pivot_cell*(MAX_NEIGHBORS + 1)];
      if (neighbor >= 0) {
        swap(board, neighbor, pivot_cell);
      }
    } break;
    case MUTATE_ROLL_FACE: {
      int cface = i % DIE_FACES;
      board[pivot_cell] = cface + die_offs(board[pivot_cell]);
      pivot_cell = (cface == DIE_FACES - 1) ? rnd_cell(&seed) : pivot_cell;
    } break;
    case MUTATE_ROLL_FACE2: {
      int d1 = i % DIE_FACES; 
      int d2 = i / DIE_FACES;
      board[pivot_cell] =  d1 + die_offs(board[pivot_cell]);
      board[pivot_cell2] = d2 + die_offs(board[pivot_cell2]);
    } break;

    case MUTATE_SWAP_ROLL: {
      int nswaps = rnd(&seed) % MAX_SWAPS;
      int c = pivot_cell;
      for (int j = 0; j < nswaps; j++) {
        int c1 = rnd_cell(&seed);
        swap(board, c, c1);
        c = c1;
      }

      int nrolls = rnd(&seed) % MAX_ROLLS;
      for (int j = 0; j < nrolls; j++) {
        random_flip(board, rnd_cell(&seed), c_num_dice, &seed);
      }
    } break;
    default: {}
    }

    ushort score = eval_board(c_trie_nodes, c_num_trie_nodes, c_trie_edge_labels, c_trie_edge_targets,
      c_dice, c_cell_neighbors, board);
    if (score > best_score) {
      best_score = score;
      for (int j = 0; j < BOARD_SIZE; j++) best_board[j] = board[j];
    }
  }
  
  for (int j = 0; j < BOARD_SIZE; j++) g_boards[id].cells[j] = best_board[j];
  g_boards[id].age = (g_boards[id].score == best_score)*(g_boards[id].age + 1);
  g_boards[id].score = best_score;
}