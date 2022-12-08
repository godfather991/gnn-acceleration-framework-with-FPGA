from modules import GCN, SAGE
import torch
import torch.nn.functional as F
import argparse
from dgl.data import CoraGraphDataset, CiteseerGraphDataset, PubmedGraphDataset
from dgl import AddSelfLoop
import dgl
import numpy as np
import yaml
from utils import get_upper_multiples_16, enlarge_and_save
import os


class Counter:
    def __init__(self, names) -> None:
        self.states = {}
        for name in names:
            self.states[name] = 0
    
    def add(self, name):
        if name in self.states.keys():
            self.states[name] += 1
        else:
            self.states[name] = 1
        return int(self.states[name])
    
    def query(self, name):
        assert name in self.states.keys()

        return int(self.states[name])

class GCNTracer:
    def __init__(self, root, model, g):
        self.root = root
        self.model = model
        self.g = g

    def generate_ir(self):
        model.eval()
        final = []
        counter = Counter(["fc", "agg", "feat"])
        counter.add("feat")
        for (i, layer) in enumerate(self.model.layers):
            layer_name = layer.__class__.__name__
            if layer_name == "GraphConv":
                reduce_type = "sum"
                relu = False
                bias = 'bias' in layer.state_dict()
                assert bias == False, "No support for bias yet"
                if layer.__dict__['_activation'] is not None:
                    if layer.__dict__['_activation'].__name__ == "relu":
                        relu = True
                in_feat = get_upper_multiples_16(layer.__dict__['_in_feats'])
                out_feat = get_upper_multiples_16(layer.__dict__['_out_feats'])
                num_nodes = self.g.num_nodes()
                mm = {}
                agg = {}

                if in_feat > out_feat:
                    # Add mm
                    mm['op_type'] = 'mm'
                    fc_num = counter.add("fc")
                    mm['op_name'] = f"fc{fc_num}"
                    feat_num = counter.query("feat")
                    mm['op_input_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, in_feat], "read_data_path": f"feat{feat_num}.npy"}
                    mm['op_acc_data'] = None
                    feat_num = counter.add("feat")
                    mm['op_output_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, out_feat], "write_data_path": f"feat{feat_num}.npy"}
                    mm['op_weight'] = {"data_name": f"fc{fc_num}_weight", "data_shape": [in_feat, out_feat], "read_data_path": f"fc{fc_num}_weight.npy"}
                    mm['accumulation'] = False
                    mm['bias'] = False
                    mm['relu'] = False
                    final.append(mm)

                    # Add agg
                    agg['op_type'] = 'agg'
                    agg_num = counter.add("agg")
                    agg['op_name'] = f"agg{agg_num}"
                    feat_num = counter.query("feat")
                    agg['op_input_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, out_feat], "read_data_path": f"feat{feat_num}.npy"}
                    feat_num = counter.add("feat")
                    agg['op_output_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, out_feat], "write_data_path": f"feat{feat_num}.npy"}
                    agg['op_adj'] = {"data_name": f"agg{agg_num}_adj", "data_shape": [num_nodes, num_nodes], "non_zeros": g.num_edges(), "read_data_path": f"agg{agg_num}_adj.npy", "read_index_path": f"agg{agg_num}_index.npy"}
                    if bias:
                        agg['op_bias'] = {"data_name": f"bias{i}", "data_shape": [1, out_feat], "read_data_path": f"bias{i}.npy"}
                    agg['apply'] = True
                    agg['reduce_type'] = reduce_type
                    agg['bias'] = bias
                    agg['relu'] = relu
                    final.append(agg)
                
                else:
                    agg['op_type'] = 'agg'
                    agg_num = counter.add("agg")
                    agg['op_name'] = f"agg{agg_num}"
                    feat_num = counter.query("feat")
                    agg['op_input_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, in_feat], "read_data_path": f"feat{feat_num}.npy"}
                    feat_num = counter.add("feat")
                    agg['op_output_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, in_feat], "write_data_path": f"feat{feat_num}.npy"}
                    agg['op_adj'] = {"data_name": f"agg{agg_num}_adj", "data_shape": [num_nodes, num_nodes], "non_zeros": g.num_edges(), "read_data_path": f"agg{agg_num}_adj.npy", "read_index_path": f"agg{agg_num}_index.npy"}
                    agg['apply'] = True
                    agg['reduce_type'] = reduce_type
                    agg['bias'] = False
                    agg['relu'] = False
                    final.append(agg)
                    
                    mm['op_type'] = 'mm'
                    fc_num = counter.add("fc")
                    mm['op_name'] = f"fc{fc_num}"
                    feat_num = counter.query("feat")
                    mm['op_input_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, in_feat], "read_data_path": f"feat{feat_num}.npy"}
                    mm['op_acc_data'] = None
                    feat_num = counter.add("feat")
                    mm['op_output_data'] = {"data_name": f"feat{feat_num}", "data_shape": [num_nodes, out_feat], "write_data_path": f"feat{feat_num}.npy"}
                    mm['op_weight'] = {"data_name": f"fc{fc_num}_weight", "data_shape": [in_feat, out_feat], "read_data_path": f"fc{fc_num}_weight.npy"}
                    if bias:
                        mm['op_bias'] = {"data_name": f"bias{i}", "data_shape": [1, out_feat], "read_data_path": f"bias{i}.npy"}
                    mm['accumulation'] = False
                    mm['bias'] = bias
                    mm['relu'] = relu
                    final.append(mm)

        f = open(os.path.join(self.root, "ir_generated.yaml"), "w")
        yaml.dump(final, f)

    def save_adj(self, norm, name):

        tg = dgl.reorder_graph(self.g, edge_permute_algo='src')
        tg = dgl.reorder_graph(tg, edge_permute_algo='dst') # Sort for the [dst->src] output

        in_degs = tg.in_degrees().float().clamp(min=1)
        out_degs = tg.out_degrees().float().clamp(min=1)

        tg.ndata['r_norm'] = 1.0 / in_degs
        tg.ndata['l_norm'] = 1.0 / out_degs
        if norm == "left":
            def copy(edges):
                return {'norm': edges.src['l_norm']} # After sorting, it should get from src.
        elif norm == "right":
            def copy(edges):
                return {'norm': edges.dst['r_norm']}
        elif norm == "both":
            tg.ndata['l_norm'] = torch.pow(in_degs, -0.5)
            tg.ndata['r_norm'] = torch.pow(out_degs, -0.5)
            def copy(edges):
                return {'norm': edges.dst['l_norm'] * edges.src['r_norm']}

        tg.apply_edges(copy)

        agg_adj = tg.edata['norm'].cpu().numpy().transpose()
        f = open(os.path.join(self.root, f"{name}_adj.npy"), "wb")
        np.save(f, agg_adj)
        f.close()

        coo = tg.adjacency_matrix(transpose = True ,scipy_fmt = 'coo')
        row_ids = np.expand_dims(coo.row, axis=0)
        col_ids = np.expand_dims(coo.col, axis=0)
        agg_index = np.concatenate((row_ids, col_ids), axis=0)
        f = open(os.path.join(self.root, f"{name}_index.npy"), "wb")
        np.save(f, agg_index)
        f.close()

    def save_all(self):
        counter = Counter(["fc", "agg"])
        self.model.eval()
        for (i, layer) in enumerate(model.layers):
            if i == 0:
                enlarge_and_save(self.root, self.g.ndata['feat'], 1, "feat1")
            layer_name = layer.__class__.__name__
            if layer_name == "GraphConv":
                fc_num = counter.add("fc")
                enlarge_and_save(self.root, layer.state_dict()['weight'], (0,1), f"fc{fc_num}_weight")
                if 'bias' in layer.state_dict():
                    enlarge_and_save(self.root, layer.state_dict()['bias'], (0,1), f"bias{fc_num}")
                agg_num = counter.add("agg")
                self.save_adj(layer._norm, f"agg{agg_num}")
    
    def __call__(self):
        self.generate_ir()
        self.save_all()

class SAGETracer:
    def __init__(self, root, model, g):
        self.root = root
        self.model = model
        self.g = g
    
    def trace_mm(self, counter, num_nodes, in_feat, out_feat):
        mm = {}
        mm['op_type'] = 'mm'
        fc_num = counter.add("fc")
        mm['op_name'] = f"fc{fc_num}"
        in_feat_num = counter.query("feat")
        mm['op_input_data'] = {"data_name": f"feat{in_feat_num}", "data_shape": [num_nodes, in_feat], "read_data_path": f"feat{in_feat_num}.npy"}
        mm['op_acc_data'] = None
        out_feat_num = counter.add("feat")
        mm['op_output_data'] = {"data_name": f"feat{out_feat_num}", "data_shape": [num_nodes, out_feat], "write_data_path": f"feat{out_feat_num}.npy"}
        mm['op_weight'] = {"data_name": f"fc{fc_num}_weight", "data_shape": [in_feat, out_feat], "read_data_path": f"fc{fc_num}_weight.npy"}
        mm['accumulation'] = False
        mm['bias'] = False
        mm['relu'] = False
        return (counter, mm)
    
    def trace_mm_f(self, counter, num_nodes, in_feat, out_feat, in_feat_num):
        mm = {}
        mm['op_type'] = 'mm'
        fc_num = counter.add("fc")
        mm['op_name'] = f"fc{fc_num}"
        mm['op_input_data'] = {"data_name": f"feat{in_feat_num}", "data_shape": [num_nodes, in_feat], "read_data_path": f"feat{in_feat_num}.npy"}
        acc_feat_num = counter.query("feat")
        mm['op_acc_data'] = {"data_name": f"feat{acc_feat_num}", "data_shape": [num_nodes, out_feat], "read_data_path": f"feat{acc_feat_num}.npy"}
        out_feat_num = counter.add("feat")
        mm['op_output_data'] = {"data_name": f"feat{out_feat_num}", "data_shape": [num_nodes, out_feat], "write_data_path": f"feat{out_feat_num}.npy"}
        mm['op_weight'] = {"data_name": f"fc{fc_num}_weight", "data_shape": [in_feat, out_feat], "read_data_path": f"fc{fc_num}_weight.npy"}
        mm['accumulation'] = True
        mm['bias'] = False
        mm['relu'] = False
        return (counter, mm)

    def trace_agg(self, counter, num_nodes, feat_len, reduce_type, apply):
        agg = {}
        agg['op_type'] = 'agg'
        agg_num = counter.add("agg")
        agg['op_name'] = f"agg{agg_num}"
        in_feat_num = counter.query("feat")
        agg['op_input_data'] = {"data_name": f"feat{in_feat_num}", "data_shape": [num_nodes, feat_len], "read_data_path": f"feat{in_feat_num}.npy"}
        out_feat_num = counter.add("feat")
        agg['op_output_data'] = {"data_name": f"feat{out_feat_num}", "data_shape": [num_nodes, feat_len], "write_data_path": f"feat{out_feat_num}.npy"}
        if apply:
            agg['op_adj'] = {"data_name": f"agg{agg_num}_adj", "data_shape": [num_nodes, num_nodes], "non_zeros": self.g.num_edges(), "read_data_path": f"agg{agg_num}_adj.npy", "read_index_path": f"agg{agg_num}_index.npy"}
        else:
            agg['op_adj'] = {"data_name": f"agg{agg_num}_adj", "data_shape": [num_nodes, num_nodes], "non_zeros": self.g.num_edges(), "read_data_path": f"agg{agg_num}_adj.npy"}
        agg['apply'] = apply
        agg['reduce_type'] = reduce_type
        agg['bias'] = False
        agg['relu'] = False
        return (counter, agg)
    
    def generate_ir(self):
        self.model.eval()
        final = []
        counter = Counter(["fc", "agg", "feat"])
        counter.add("feat")
        for (i, layer) in enumerate(self.model.layers):
            layer_name = layer.__class__.__name__
            if layer_name == "SAGEConv":
                relu = False
                bias = 'bias' in layer.state_dict()
                assert bias == False, "No support for bias yet"
                if layer.__dict__['_activation'] is not None:
                    if layer.__dict__['_activation'].__name__ == "relu":
                        relu = True
                in_feat = get_upper_multiples_16(layer.__dict__['_in_feats'])
                out_feat = get_upper_multiples_16(layer.__dict__['_out_feats'])
                num_nodes = self.g.num_nodes()

                if layer._aggre_type == "mean":
                    mm = {}
                    agg = {}
                    mm_f = {}
                    in_feat_num = counter.query("feat")
                    reduce_type = "sum"
                    if in_feat > out_feat:
                        (counter, mm) = self.trace_mm(counter, num_nodes, in_feat, out_feat)
                        final.append(mm)

                        (counter, agg) = self.trace_agg(counter, num_nodes, out_feat, reduce_type, apply=True)
                        final.append(agg)

                        (counter, mm_f) = self.trace_mm_f(counter, num_nodes, in_feat, out_feat, in_feat_num)
                        if bias:
                            mm_f['op_bias'] = {"data_name": f"bias{i}", "data_shape": [1, out_feat], "read_data_path": f"bias{i}.npy"}
                        mm_f['accumulation'] = True
                        mm_f['bias'] = bias
                        mm_f['relu'] = relu
                        final.append(mm_f)

                    else:
                        (counter, agg) = self.trace_agg(counter, num_nodes, in_feat, reduce_type, apply=True)
                        final.append(agg)

                        (counter, mm) = self.trace_mm(counter, num_nodes, in_feat, out_feat)
                        final.append(mm)

                        (counter, mm_f) = self.trace_mm_f(counter, num_nodes, in_feat, out_feat, in_feat_num)
                        if bias:
                            mm_f['op_bias'] = {"data_name": f"bias{i}", "data_shape": [1, out_feat], "read_data_path": f"bias{i}.npy"}
                        mm_f['accumulation'] = True
                        mm_f['bias'] = bias
                        mm_f['relu'] = relu
                        final.append(mm_f)

        f = open(os.path.join(self.root, "ir_generated.yaml"), "w")
        yaml.dump(final, f)

    def save_adj(self, norm, name):

        tg = dgl.reorder_graph(self.g, edge_permute_algo='src')
        tg = dgl.reorder_graph(tg, edge_permute_algo='dst') # Sort for the [dst->src] output

        in_degs = tg.in_degrees().float().clamp(min=1)

        tg.ndata['r_norms'] = 1.0 / in_degs
        if norm == "mean":
            def copy(edges):
                return {'norm': edges.dst['r_norms']}
        elif norm == "gcn":
            def copy(edges):
                return {'norm': edges.dst['r_norms'] + (edges.dst['_ID'] == edges.src['_ID'])}
        else:
            def copy(edges):
                return {'norm': 1}
        
        tg.apply_edges(copy)

        agg_adj = tg.edata['norm'].cpu().numpy().transpose()
        f = open(os.path.join(self.root, f"{name}_adj.npy"), "wb")
        np.save(f, agg_adj)
        f.close()

        coo = tg.adjacency_matrix(transpose = True ,scipy_fmt = 'coo')
        row_ids = np.expand_dims(coo.row, axis=0)
        col_ids = np.expand_dims(coo.col, axis=0)
        agg_index = np.concatenate((row_ids, col_ids), axis=0)
        f = open(os.path.join(self.root, f"{name}_index.npy"), "wb")
        np.save(f, agg_index)
        f.close()

    def save_all(self):
        counter = Counter(["fc", "agg"])
        self.model.eval()
        for (i, layer) in enumerate(self.model.layers):
            if i == 0:
                enlarge_and_save(self.root, self.g.ndata['feat'], 1, "feat1")
            layer_name = layer.__class__.__name__
            if layer_name == "SAGEConv":
                if layer._aggre_type == "mean" or layer._aggre_type == "pool":
                    fc_num = counter.add("fc")
                    enlarge_and_save(self.root, layer.state_dict()['weight'], (0,1), f"fc{fc_num}_weight")
                    fc_num = counter.add("fc")
                    enlarge_and_save(self.root, layer.state_dict()['weight'], (0,1), f"fc{fc_num}_weight")
                elif layer._aggre_type == "gcn":
                    fc_num = counter.add("fc")
                    enlarge_and_save(self.root, layer.state_dict()['weight'], (0,1), f"fc{fc_num}_weight")
                else:
                    raise ValueError('Unsupported aggregation type: {}'.format(layer._aggre_type))

                if 'bias' in layer.state_dict():
                    enlarge_and_save(self.root, layer.state_dict()['bias'], (0,1), f"bias{i}")
                agg_num = counter.add("agg")
                self.save_adj(layer._aggre_type, f"agg{agg_num}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=str, default="../IR_and_data/gcn-2-16-pubmed", 
                        help="Path to the pre-trained model")
    parser.add_argument("--dataset", type=str, default="pubmed",
                        help="Dataset name ('cora', 'citeseer', 'pubmed').")
    parser.add_argument("--model", type=str, default="gcn")
    args = parser.parse_args()

    dgl_root = "../IR_and_data/"
    raw_dir = os.path.join(dgl_root,"dgl")
    # load and preprocess dataset
    transform = AddSelfLoop()  # by default, it will first remove self-loops to prevent duplication
    if args.dataset == 'cora':
        data = CoraGraphDataset(raw_dir=raw_dir, transform=transform)
    elif args.dataset == 'citeseer':
        data = CiteseerGraphDataset(raw_dir=raw_dir, transform=transform)
    elif args.dataset == 'pubmed':
        data = PubmedGraphDataset(raw_dir=raw_dir, transform=transform)
    else:
        raise ValueError('Unknown dataset: {}'.format(args.dataset))
    g = data[0]
    model_path = os.path.join(args.root, "model.pt")
    model = torch.load(model_path)
    if args.model == "gcn":
        tracer = GCNTracer(args.root, model, g)
        tracer()
    elif args.model == "sage":
        tracer = SAGETracer(args.root, model, g)
        tracer.generate_ir()
        tracer.save_all()



